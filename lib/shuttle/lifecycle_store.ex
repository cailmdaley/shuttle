defmodule Shuttle.LifecycleStore do
  @moduledoc """
  Standing-role lifecycle transitions (accept / resume / mark-awaiting), plus the
  force-dispatch `rearm` shared by standing and pinned roles, written straight to
  the felt document.

  The document is the single source of truth: `status`, `tempered`, `outcome`,
  the cron `schedule`, `agent`, `host`. Accept and resume re-arm an awaiting
  STANDING role (`status: closed` + untempered) by writing `status: active` back
  to the document; `mark_awaiting` is the worker-exit writer that flips it closed.
  `rearm` is the force-dispatch open: it writes `status: active` for any perennial
  role — standing or pinned — so the board's strip → In-flight "start" gesture
  loops a parked pinned role (open → active). There is no runtime store (slice 6
  deleted it) and no review axis (slice 4 removed it): the document carries the
  entire lifecycle, and `next_due` is recomputed from the cron schedule on the
  next poll. Pinned is not cyclical (Option D): it loops while active and parks
  at open, so it has no accept/awaiting cycle here — only the `rearm` open.
  """

  alias Shuttle.{Cron, FeltStores}

  # Legacy + daemon-owned shuttle keys wiped from the block on every accept /
  # resume / mark-awaiting rewrite (clean cutover, slice 5: `enabled` and
  # `review` are gone; `next_due_at` / `last_run_at` / `session` are
  # daemon-owned and don't live in the synced document).
  @runtime_keys ~w(enabled review next_due_at last_run_at session)

  @spec accept(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def accept(fiber_id, _opts \\ []) when is_binary(fiber_id) do
    with {:ok, path, frontmatter, body} <- read_fiber(fiber_id),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         :ok <- require_standing(shuttle),
         :ok <- require_doc_acceptable(frontmatter) do
      # Awaiting is `status: closed` + untempered in the document itself — there
      # is no `review.state` (slice 4 removed the review axis). Recognize it
      # straight from the doc and re-arm, advancing the cron recurrence (next_due
      # from the schedule). The previous run's outcome is preserved — it stays
      # the card's headline until the next run overwrites it (accept no longer
      # blanks it; see update_document). Accept is standing-only: a pinned role
      # is not cyclical (Option D — it loops while active, parks at open), so it
      # has no awaiting/accept cycle to advance.
      accept_from_doc(fiber_id, path, frontmatter, body, shuttle)
    end
  end

  defp accept_from_doc(fiber_id, path, frontmatter, body, shuttle) do
    with {:ok, schedule} <- require_schedule(shuttle),
         {:ok, next_due_at} <- Cron.next_occurrence(schedule, DateTime.utc_now()),
         {:ok, frontmatter} <- update_document(frontmatter) do
      # The document carries the entire lifecycle: writing `status: active` re-arms
      # the role, and `next_due` is recomputed from the cron schedule on the next
      # poll. There is no runtime row to upsert (slice 6).
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
    {:ok, frontmatter} = update_document(frontmatter)

    # Re-arm by writing `status: active`; the next poll's cron window picks the
    # role up immediately (the active document IS the re-queue). No runtime row
    # (slice 6).
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

  Awaiting is fully doc-representable: there is no review axis (slice 4) and no
  runtime row (slice 6), so this is a single felt write. It is the mirror of
  `update_document` (the accept re-arm) — it sets `status: closed` where accept
  sets `status: active`. Atomic via `write_fiber!` (tmp + rename). A no-op-shaped
  error (not standing / unreadable) returns `{:error, _}` so the caller can log
  without crashing the exit path.
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
  Re-arm a PERENNIAL role (standing or pinned) to `status: active` regardless of
  its current verdict.

  This is the **force-dispatch** re-arm: an explicit human "go" from the board
  (force-dispatch) is the verdict, so unlike `accept`/`resume` it does not
  require the awaiting precondition — it reopens a closed role whether it was
  awaiting, tempered, or composted, and (Option D) starts a parked pinned role
  by writing `open → active` so the board's strip → In-flight "start" gesture
  both spawns the worker now AND leaves the role looping. Clears
  `tempered`/`closed-at`, keeps the outcome, and wipes daemon-owned runtime keys.
  A no-op `{:ok, ...}` for a role already active, and an `{:error, _}` for a
  oneshot or unreadable fiber (a force-dispatched oneshot runs once and stays
  put — no loop to revive) so the dispatch path can log without crashing.

  Mirror of `mark_awaiting/1` (the worker-exit closer): this is the open.
  """
  @spec rearm(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def rearm(fiber_id) when is_binary(fiber_id) do
    with {:ok, path, frontmatter, body} <- read_fiber(fiber_id),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         :ok <- require_perennial(shuttle) do
      if Map.get(frontmatter, "status") == "active" do
        {:ok, "#{fiber_id} already active\n"}
      else
        {:ok, frontmatter} = update_document(frontmatter)
        write_fiber!(path, evict_runtime_keys(frontmatter), body)
        {:ok, "re-armed #{fiber_id} (status: active) for force-dispatch\n"}
      end
    end
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

  # Accept's wider precondition: any UNTEMPERED non-draft state re-arms. The
  # kanban's Temper gesture on a cyclical role resolves to accept even while
  # the run is still in flight (status: active, worker alive or just killed,
  # exit not yet marked awaiting) — "I'm done, advance the schedule" doesn't
  # wait for the exit writer. Verdict termini (tempered true/false) and drafts
  # (status: open) still reject; re-arm from active is idempotent on status.
  defp require_doc_acceptable(frontmatter) do
    status = Map.get(frontmatter, "status")

    if status in ["active", "closed"] and is_nil(Map.get(frontmatter, "tempered")) do
      :ok
    else
      {:error,
       "fiber is not acceptable (accept requires status active|closed + untempered; " <>
         "status=#{inspect(status)}, " <>
         "tempered=#{inspect(Map.get(frontmatter, "tempered"))})"}
    end
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

  # Standing = the cron-driven active→closed→active lifecycle this module's
  # accept/resume/mark_awaiting paths implement (a run closes to awaiting-review;
  # accept advances the recurrence). Pinned is NOT standing under Option D — it
  # loops while active and parks at open, with no awaiting/accept cycle — so
  # those three paths reject it along with oneshots and non-shuttle fibers.
  defp require_standing(%{"kind" => "standing"}), do: :ok
  defp require_standing(%{"mode" => "standing"}), do: :ok

  defp require_standing(shuttle),
    do:
      {:error,
       "accept/resume/mark-awaiting store path only applies to standing roles (kind=#{inspect(Map.get(shuttle, "kind"))})"}

  # Perennial = standing OR pinned: roles whose `active` state means perennial
  # dispatch (a cron loop, or the Option-D poll loop). `rearm` (the force-dispatch
  # re-arm) writes them to `active`; a oneshot is rejected — force-dispatching a
  # oneshot runs it once and leaves its status put, with no loop to revive.
  defp require_perennial(%{"kind" => kind}) when kind in ["standing", "pinned"], do: :ok
  defp require_perennial(%{"mode" => mode}) when mode in ["standing", "pinned"], do: :ok

  defp require_perennial(shuttle),
    do:
      {:error,
       "rearm only applies to standing or pinned roles (kind=#{inspect(Map.get(shuttle, "kind"))})"}

  defp require_schedule(%{"schedule" => schedule}) when is_map(schedule), do: {:ok, schedule}
  defp require_schedule(_), do: {:error, "fiber has no schedule"}

  # accept/resume both re-arm an awaiting role by writing `status: active` back
  # to the document — the sole dispatch gate (slice 5: no enabled flag, no
  # review block). tempered and closed-at are cleared so the card leaves the
  # Awaiting/Tempered/Composted columns.
  defp update_document(frontmatter) do
    frontmatter =
      frontmatter
      |> Map.put("status", "active")
      |> Map.delete("tempered")
      |> Map.delete("closed-at")

    # The outcome is never blanked on re-arm: the last run's digest stays the
    # card headline until the next run overwrites it. (Accept used to clear it
    # as a "fresh precondition for the next run", but that left a re-armed role
    # with an empty headline for the whole inter-run gap — the doc carries the
    # lifecycle, the outcome carries the latest result.)
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
