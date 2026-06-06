defmodule Shuttle.LifecycleService do
  @moduledoc """
  Daemon-side orchestration for the standing-role lifecycle verbs that mutate
  the runtime store (`accept` / `resume`).

  Both the `/api/v1/lifecycle` endpoint (operator / shuttle-ctl) and the
  `/api/v1/actions/invoke` kanban path go through here, so an accept behaves
  identically regardless of which gesture triggered it. The work is:

    1. Run the transition *through the Poller* (`Poller.lifecycle_transition/3`)
       so its in-memory lifecycle cache is refreshed from the runtime store and
       the next poll won't clobber the write back to `awaiting`.
    2. Append a felt-history event recording the transition.

  Previously the kanban path shelled out to the Go `shuttle-ctl accept`, which
  re-reads `shuttle.review.state` from the *frontmatter* — where standing-role
  review state no longer lives — and refused with "not awaiting review". Keeping
  the runtime-store-aware implementation in one in-process place avoids that
  whole class of frontmatter/runtime divergence.
  """

  alias Shuttle.{FeltStores, LifecycleStore, Poller}

  @spec accept(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def accept(fiber_id, opts \\ []) when is_binary(fiber_id) do
    with {:ok, address} <- fiber_address(fiber_id) do
      case transition(:accept, address, opts) do
        {:ok, output} ->
          record_history(address, output, "accepted standing-role run via daemon runtime store")
          {:ok, output}

        {:error, reason} ->
          {:error, to_message(reason)}
      end
    end
  end

  @spec resume(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resume(fiber_id) when is_binary(fiber_id) do
    with {:ok, address} <- fiber_address(fiber_id) do
      case transition(:resume, address, []) do
        {:ok, output} ->
          record_history(address, output, "resumed standing role via daemon runtime store")
          {:ok, output}

        {:error, reason} ->
          {:error, to_message(reason)}
      end
    end
  end

  # Clear a standing role's runtime review state on close/reopen. Unlike
  # accept/resume this writes no felt-history event — close/reopen already log
  # their own status transition, and the runtime-store clear is bookkeeping, not
  # a reviewable verdict. Routed through the Poller (when live) so the runtime
  # delete and the in-memory lifecycle-cache eviction are atomic against poll
  # cycles, mirroring accept/resume.
  @spec reset_review(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def reset_review(fiber_id) when is_binary(fiber_id) do
    with {:ok, address} <- fiber_address(fiber_id) do
      case transition(:reset_review, address, []) do
        {:ok, output} -> {:ok, output}
        {:error, reason} -> {:error, to_message(reason)}
      end
    end
  end

  # When the Poller is running (the live daemon) route through it so the runtime
  # DB write and the in-memory lifecycle-cache refresh happen atomically against
  # poll cycles — otherwise the next poll re-derives the role from the stale
  # cache and clobbers the write. When it isn't (offline lifecycle ops, unit
  # tests) write the runtime store directly; there's no cache to keep in sync.
  defp transition(verb, fiber_id, opts) do
    if is_pid(Process.whereis(Poller)) do
      Poller.lifecycle_transition(verb, fiber_id, opts)
    else
      apply(LifecycleStore, verb, lifecycle_store_args(verb, fiber_id, opts))
    end
  end

  defp lifecycle_store_args(:accept, fiber_id, opts), do: [fiber_id, opts]
  defp lifecycle_store_args(:resume, fiber_id, _opts), do: [fiber_id]
  defp lifecycle_store_args(:reset_review, fiber_id, _opts), do: [fiber_id]

  defp fiber_address(identifier) do
    case FeltStores.resolve_fiber(identifier) do
      {:ok, %{fiber_id: fiber_id}} -> {:ok, fiber_id}
      {:error, :not_found} -> {:error, "fiber not found: #{identifier}"}
    end
  end

  defp record_history(fiber_id, output, fallback) do
    summary =
      output
      |> String.split("\n", trim: true)
      |> List.first()
      |> case do
        nil -> fallback
        line -> line
      end

    append_history(fiber_id, summary)
  end

  defp append_history(fiber_id, summary) do
    with {:ok, %{host: host}} <- FeltStores.resolve_fiber(fiber_id) do
      System.cmd("felt", ["-C", host, "history", "append", fiber_id, "--summary", summary],
        stderr_to_stdout: true
      )
    end
  rescue
    _ -> nil
  end

  defp to_message(reason) when is_binary(reason), do: reason
  defp to_message(reason), do: inspect(reason)
end
