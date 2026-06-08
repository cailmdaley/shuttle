defmodule Shuttle.LifecycleStore do
  @moduledoc """
  Standing-role lifecycle transitions (accept / resume / mark-awaiting), written
  straight to the felt document.

  The document is the single source of truth: `status`, `tempered`, `outcome`,
  the cron `schedule`, `agent`, `host`. Accept and resume re-arm an awaiting
  role (`status: closed` + untempered) by writing `status: active` back to the
  document; `mark_awaiting` is the worker-exit writer that flips it closed. The
  runtime store is written for the still-living session/next_due index (gone in
  slice 6), but no review axis lives anywhere (slice 4 removed it).
  """

  alias Shuttle.{Cron, FeltStores, RuntimeStore}

  # Legacy + daemon-owned shuttle keys wiped from the block on every accept /
  # resume / mark-awaiting rewrite (clean cutover, slice 5: `enabled` and
  # `review` are gone; `next_due_at` / `last_run_at` / `session` are
  # daemon-owned and don't live in the synced document).
  @runtime_keys ~w(enabled review next_due_at last_run_at session)

  @spec accept(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def accept(fiber_id, opts \\ []) when is_binary(fiber_id) do
    keep_outcome? = Keyword.get(opts, :keep_outcome, false)

    with {:ok, path, frontmatter, body} <- read_fiber(fiber_id),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         :ok <- require_standing(shuttle),
         :ok <- require_doc_awaiting(frontmatter) do
      # Awaiting is `status: closed` + untempered in the document itself — there
      # is no `review.state` (slice 4 removed the review axis). Recognize it
      # straight from the doc and re-arm from the doc schedule.
      accept_from_doc(fiber_id, path, frontmatter, body, shuttle, keep_outcome?)
    end
  end

  defp accept_from_doc(fiber_id, path, frontmatter, body, shuttle, keep_outcome?) do
    with {:ok, schedule} <- require_schedule(shuttle),
         {:ok, next_due_at} <- Cron.next_occurrence(schedule, DateTime.utc_now()),
         {:ok, frontmatter} <- update_document(frontmatter, keep_outcome?) do
      lifecycle =
        %{
          kind: "standing",
          phase: "scheduled",
          run_id: "",
          next_due_at: next_due_at,
          last_run_at: nil
        }
        |> stamp_uid(fiber_id)

      RuntimeStore.upsert_lifecycle(runtime_store_path(), fiber_id, lifecycle)
      write_fiber!(path, evict_runtime_keys(frontmatter), body)

      {:ok, "accepted run for #{fiber_id}\n  next due: #{DateTime.to_iso8601(next_due_at)}\n"}
    end
  end

  @spec resume(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resume(fiber_id) when is_binary(fiber_id) do
    with {:ok, path, frontmatter, body} <- read_fiber(fiber_id),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         :ok <- require_standing(shuttle),
         :ok <- require_doc_awaiting(frontmatter) do
      resume_from_doc(fiber_id, path, frontmatter, body)
    end
  end

  defp resume_from_doc(fiber_id, path, frontmatter, body) do
    now = DateTime.utc_now()
    {:ok, frontmatter} = update_document(frontmatter, true)

    lifecycle =
      %{
        kind: "standing",
        phase: "scheduled",
        run_id: nil,
        next_due_at: now,
        last_run_at: nil
      }
      |> stamp_uid(fiber_id)

    RuntimeStore.upsert_lifecycle(runtime_store_path(), fiber_id, lifecycle)
    write_fiber!(path, evict_runtime_keys(frontmatter), body)

    {:ok,
     "resumed #{fiber_id} (standing role; re-queued for immediate dispatch)\n" <>
       "  next_due_at:  #{DateTime.to_iso8601(now)} (immediate)\n" <>
       "  note: use 'accept' to advance the recurrence instead\n"}
  end

  @doc """
  Standing-worker exit writer: mark a role awaiting review by writing
  `status: closed` (untempered) straight to the felt document — the new-model
  awaiting signal, recognized by `accept`/`resume` (`doc_awaiting?`), the
  poller's `eligible?` gate, and the kanban classifier. It is also the
  don't-re-fire gate: a closed role is never dispatch-eligible, so the
  `active → closed → active` cycle encodes "already ran this occurrence."

  Deliberately does NOT touch `review` or the runtime row: awaiting is fully
  doc-representable, and routing through `shuttle-ctl close` would run
  `resetStandingReview`/`clearRuntimeReviewLifecycle` and erase the marker. This
  is the mirror of `update_document` (the accept re-arm) — it sets
  `status: closed` where accept sets `status: active`. Atomic via `write_fiber!`
  (tmp + rename). A no-op-shaped error (not standing / unreadable) returns
  `{:error, _}` so the caller can log without crashing the exit path.
  """
  @spec mark_awaiting(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def mark_awaiting(fiber_id) when is_binary(fiber_id) do
    with {:ok, path, frontmatter, body} <- read_fiber(fiber_id),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         :ok <- require_standing(shuttle) do
      frontmatter =
        frontmatter
        |> Map.put("status", "closed")
        |> Map.put("closed-at", DateTime.to_iso8601(DateTime.utc_now()))
        |> Map.delete("tempered")

      write_fiber!(path, evict_runtime_keys(frontmatter), body)

      {:ok, "marked #{fiber_id} awaiting review (status: closed, untempered)\n"}
    end
  end

  @doc """
  Clear a standing role's runtime lifecycle row on close/reopen.

  Close and reopen end (or restart) a role's cycle; this drops the host-local
  runtime row so no stale next_due/session lingers for the kanban invoke path or
  a remote daemon (atomic against poll cycles via
  `Poller.refresh_lifecycle_entry`). The document carries the lifecycle truth
  (status + tempered) — there is no review axis to reset (slice 4). A no-op when
  the fiber has no runtime row (oneshots, already-clean roles). Named
  `reset_review` for the invoke verb that calls it; the work is a row delete.
  """
  @spec reset_review(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def reset_review(fiber_id) when is_binary(fiber_id) do
    existing = RuntimeStore.fetch_lifecycle(runtime_store_path(), fiber_id)
    RuntimeStore.delete_lifecycle(runtime_store_path(), fiber_id)

    note = if is_nil(existing), do: "", else: " (cleared runtime row)"

    {:ok, "reset review lifecycle for #{fiber_id}#{note}\n"}
  end

  defp read_fiber(fiber_id) do
    with {:ok, path} <- resolve_fiber_path(fiber_id),
         {:ok, text} <- File.read(path),
         {:ok, frontmatter_yaml, body} <- split_frontmatter(text),
         {:ok, frontmatter} <- YamlElixir.read_from_string(frontmatter_yaml) do
      {:ok, path, stringify_keys(frontmatter || %{}), body}
    else
      {:error, :not_found} -> {:error, "fiber not found: #{fiber_id}"}
      {:error, reason} when is_atom(reason) -> {:error, to_string(reason)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp resolve_fiber_path(fiber_id) do
    case FeltStores.resolve_fiber(fiber_id) do
      {:ok, %{path: path}} -> {:ok, path}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp split_frontmatter("---\n" <> rest) do
    case :binary.split(rest, "\n---", []) do
      [frontmatter, body] -> {:ok, frontmatter, body}
      _ -> {:error, "missing closing frontmatter delimiter"}
    end
  end

  defp split_frontmatter(_), do: {:error, "missing opening frontmatter delimiter"}

  defp shuttle_block(%{"shuttle" => shuttle}) when is_map(shuttle), do: {:ok, shuttle}
  defp shuttle_block(_), do: {:error, "fiber has no shuttle: block"}

  # Awaiting, read straight from the document: `status: closed` with no verdict
  # (`tempered` unset). `tempered: false` (composted) and `tempered: true` are
  # termini, not awaiting. This is the sole accept/resume precondition (slice 4:
  # no `review.state` to consult).
  defp doc_awaiting?(frontmatter) do
    Map.get(frontmatter, "status") == "closed" and is_nil(Map.get(frontmatter, "tempered"))
  end

  defp require_doc_awaiting(frontmatter) do
    if doc_awaiting?(frontmatter) do
      :ok
    else
      {:error,
       "fiber is not awaiting review (accept/resume require status:closed + untempered; " <>
         "status=#{inspect(Map.get(frontmatter, "status"))}, " <>
         "tempered=#{inspect(Map.get(frontmatter, "tempered"))})"}
    end
  end

  # Key the runtime row by the fiber's intrinsic uid, like the poller does, so
  # accept/resume never births a second address-keyed row for a fiber the poller
  # already tracks under its uid. This dual-writer-two-keys split is the exact
  # root of the daily-practice wedge (finding-live-wedge-anatomy). Falls back to
  # address-keying when felt can't resolve a uid (legacy/test fibers).
  defp stamp_uid(lifecycle, fiber_id) do
    case resolve_uid(fiber_id) do
      uid when is_binary(uid) and uid != "" -> Map.put(lifecycle, :uid, uid)
      _ -> lifecycle
    end
  end

  defp resolve_uid(fiber_id) do
    case FeltStores.resolve_fiber(fiber_id) do
      {:ok, %{uid: uid}} -> uid
      _ -> nil
    end
  end

  defp require_standing(%{"kind" => "standing"}), do: :ok
  defp require_standing(%{"mode" => "standing"}), do: :ok

  defp require_standing(shuttle),
    do:
      {:error,
       "accept/resume store path only applies to standing roles (kind=#{inspect(Map.get(shuttle, "kind"))})"}

  defp require_schedule(%{"schedule" => schedule}) when is_map(schedule), do: {:ok, schedule}
  defp require_schedule(_), do: {:error, "fiber has no schedule"}

  # accept/resume both re-arm an awaiting role by writing `status: active` back
  # to the document — the sole dispatch gate (slice 5: no enabled flag, no
  # review block). tempered and closed-at are cleared so the card leaves the
  # Awaiting/Tempered/Composted columns.
  defp update_document(frontmatter, keep_outcome?) do
    frontmatter =
      frontmatter
      |> Map.put("status", "active")
      |> Map.delete("tempered")
      |> Map.delete("closed-at")

    frontmatter =
      if keep_outcome?, do: frontmatter, else: Map.put(frontmatter, "outcome", "")

    {:ok, frontmatter}
  end

  defp evict_runtime_keys(%{"shuttle" => shuttle} = frontmatter) do
    %{frontmatter | "shuttle" => Map.drop(shuttle, @runtime_keys)}
  end

  defp write_fiber!(path, frontmatter, body) do
    tmp = path <> ".tmp"
    File.write!(tmp, ["---\n", yaml(frontmatter), "---\n", body, ensure_trailing_newline(body)])
    File.rename!(tmp, path)
    :ok
  end

  defp runtime_store_path do
    System.get_env("SHUTTLE_RUNTIME_STORE") || RuntimeStore.default_path()
  end

  defp stringify_keys(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp yaml(map) do
    map
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map_join("", fn {key, value} -> yaml_field(key, value, 0) end)
  end

  defp yaml_field(key, value, indent) when is_map(value) do
    "#{spaces(indent)}#{key}:\n" <> yaml_nested(value, indent + 2)
  end

  defp yaml_field(key, value, indent) when is_list(value) do
    "#{spaces(indent)}#{key}:\n" <>
      Enum.map_join(value, "", fn item -> "#{spaces(indent + 2)}- #{yaml_scalar(item)}\n" end)
  end

  defp yaml_field(key, value, indent), do: "#{spaces(indent)}#{key}: #{yaml_scalar(value)}\n"

  defp yaml_nested(map, indent) do
    map
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map_join("", fn {key, value} -> yaml_field(key, value, indent) end)
  end

  defp yaml_scalar(value) when is_boolean(value), do: to_string(value)
  defp yaml_scalar(value) when is_integer(value), do: to_string(value)
  defp yaml_scalar(value) when is_float(value), do: to_string(value)
  defp yaml_scalar(nil), do: "null"

  defp yaml_scalar(value) when is_binary(value) do
    cond do
      value == "" -> ~s("")
      String.match?(value, ~r/^[A-Za-z0-9_\/.\-:@+]+$/) -> value
      true -> inspect(value)
    end
  end

  defp yaml_scalar(value), do: inspect(value)

  defp spaces(n), do: String.duplicate(" ", n)
  defp ensure_trailing_newline(""), do: ""
  defp ensure_trailing_newline(body), do: if(String.ends_with?(body, "\n"), do: "", else: "\n")
end
