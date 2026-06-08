defmodule Shuttle.LifecycleService do
  @moduledoc """
  Daemon-side orchestration for the standing-role lifecycle verbs that re-arm an
  awaiting role by writing the felt document (`accept` / `resume`).

  Both the `/api/v1/lifecycle` endpoint (operator / shuttle-ctl) and the
  `/api/v1/actions/invoke` kanban path go through here, so an accept behaves
  identically regardless of which gesture triggered it. The work is:

    1. Run the transition *through the Poller* (`Poller.lifecycle_transition/3`)
       so the felt-document write is atomic against poll cycles.
    2. Append a felt-history event recording the transition.

  Awaiting is `status: closed` + untempered in the document itself (slice 4: no
  review axis); re-arm writes `status: active` and `next_due` is recomputed from
  the cron schedule on the next poll (slice 6: no runtime store).
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

  # When the Poller is running (the live daemon) route through it so the felt
  # document write happens atomically against poll cycles — otherwise a
  # concurrent poll could read a half-written document. When it isn't (offline
  # lifecycle ops, unit tests) write the document directly.
  defp transition(verb, fiber_id, opts) do
    if is_pid(Process.whereis(Poller)) do
      Poller.lifecycle_transition(verb, fiber_id, opts)
    else
      apply(LifecycleStore, verb, lifecycle_store_args(verb, fiber_id, opts))
    end
  end

  defp lifecycle_store_args(:accept, fiber_id, opts), do: [fiber_id, opts]
  defp lifecycle_store_args(:resume, fiber_id, _opts), do: [fiber_id]

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
