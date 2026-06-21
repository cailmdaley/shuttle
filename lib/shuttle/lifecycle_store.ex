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
  loops a parked pinned role (open → active). There is no runtime store and no
  review axis: the document carries the
  entire lifecycle, and `next_due` is recomputed from the cron schedule on the
  next poll. Pinned is not cyclical (Option D): it loops while active and parks
  at open, so it has no accept/awaiting cycle here — only the `rearm` open.
  """

  alias Shuttle.FiberDoc

  # Legacy + daemon-owned shuttle keys wiped from the block on every accept /
  # resume / mark-awaiting rewrite: `enabled` and `review` no longer exist;
  # `next_due_at` / `last_run_at` / `session` are daemon-owned and don't live in
  # the synced document.
  @runtime_keys ~w(enabled review next_due_at last_run_at session)

  @spec accept(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def accept(fiber_id, _opts \\ []) when is_binary(fiber_id) do
    with {:ok, path, raw_fm, frontmatter, body} <- FiberDoc.read(fiber_id),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         :ok <- require_standing(shuttle),
         :ok <- require_doc_acceptable(frontmatter) do
      # Awaiting is `status: closed` + untempered in the document itself — there
      # is no `review.state` axis. Recognize it
      # straight from the doc and re-arm, advancing the cron recurrence (next_due
      # from the schedule). The previous run's outcome is preserved — it stays
      # the card's headline until the next run overwrites it (accept no longer
      # blanks it; see rearm_ops). Accept is standing-only: a pinned role
      # is not cyclical (Option D — it loops while active, parks at open), so it
      # has no awaiting/accept cycle to advance.
      accept_from_doc(fiber_id, path, raw_fm, body, shuttle)
    end
  end

  defp accept_from_doc(fiber_id, path, raw_fm, body, shuttle) do
    with {:ok, _schedule} <- require_schedule(shuttle) do
      # The document carries the entire lifecycle: writing `status: active` re-arms
      # the role, `handed_off_at` concludes the prior run (one atomic write), and
      # `next_due` is recomputed by felt on the next poll (the daemon no longer
      # parses cron — Stage 4b). There is no runtime row to upsert, and the precise
      # next-due timestamp rides the board's polled snapshot, not this message.
      FiberDoc.write!(path, raw_fm, body, rearm_ops() ++ [conclude_run_op()] ++ evict_runtime_ops())

      {:ok, "accepted run for #{fiber_id} (re-armed; next run on the schedule's next tick)\n"}
    end
  end

  @spec resume(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resume(fiber_id) when is_binary(fiber_id) do
    with {:ok, path, raw_fm, frontmatter, body} <- FiberDoc.read(fiber_id),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         :ok <- require_standing(shuttle),
         :ok <- require_doc_awaiting(frontmatter) do
      resume_from_doc(fiber_id, path, raw_fm, body)
    end
  end

  defp resume_from_doc(fiber_id, path, raw_fm, body) do
    now = DateTime.utc_now()

    # Re-arm by writing `status: active`; the next poll's cron window picks the
    # role up immediately (the active document IS the re-queue). `handed_off_at`
    # concludes the prior run in the same atomic write. No runtime row.
    FiberDoc.write!(path, raw_fm, body, rearm_ops() ++ [conclude_run_op()] ++ evict_runtime_ops())

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

  Awaiting is fully doc-representable: there is no review axis and no
  runtime row, so this is a single felt write. It is the mirror of
  `update_document` (the accept re-arm) — it sets `status: closed` where accept
  sets `status: active`. Atomic via `write_fiber!` (tmp + rename). A no-op-shaped
  error (not standing / unreadable) returns `{:error, _}` so the caller can log
  without crashing the exit path.
  """
  @spec mark_awaiting(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def mark_awaiting(fiber_id) when is_binary(fiber_id) do
    with {:ok, path, raw_fm, frontmatter, body} <- FiberDoc.read(fiber_id),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         :ok <- require_standing(shuttle) do
      ops =
        [
          {:put, "status", "closed"},
          {:put, "closed-at", DateTime.to_iso8601(DateTime.utc_now())},
          {:delete, "tempered"}
        ] ++ evict_runtime_ops()

      FiberDoc.write!(path, raw_fm, body, ops)

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
    with {:ok, path, raw_fm, frontmatter, body} <- FiberDoc.read(fiber_id),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         :ok <- require_perennial(shuttle) do
      if Map.get(frontmatter, "status") == "active" do
        {:ok, "#{fiber_id} already active\n"}
      else
        FiberDoc.write!(path, raw_fm, body, rearm_ops() ++ [conclude_run_op()] ++ evict_runtime_ops())
        {:ok, "re-armed #{fiber_id} (status: active) for force-dispatch\n"}
      end
    end
  end

  @doc """
  Pinned-worker exit writer: park an interactive role back to its rest state by
  writing `status: open` straight to the felt document — the strip resting state.

  A pinned role is an interactive interface, not a loop: when its session ends
  (the human killed the tmux session, a crash, or a clean exit), the role must
  return to the **pinned strip** (`status: open`), not stay stuck `active` with
  no live worker in In-flight, and not relaunch (the poller's `filter_eligible`
  already excludes pinned from the autonomous tick). Resume from the strip
  (force-dispatch → `rearm`) re-attaches.

  Mirror of `mark_awaiting/1` (the standing-role closer, which writes
  `status: closed`): this is the pinned closer. Pinned-only — a no-op-shaped
  `{:error, _}` for any other kind so the exit path can log without crashing.
  Idempotent: `{:ok, ...}` if already parked.
  """
  @spec park(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def park(fiber_id) when is_binary(fiber_id) do
    with {:ok, path, raw_fm, frontmatter, body} <- FiberDoc.read(fiber_id),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         :ok <- require_pinned(shuttle) do
      if Map.get(frontmatter, "status") == "open" do
        {:ok, "#{fiber_id} already parked\n"}
      else
        ops = [{:put, "status", "open"}, {:delete, "closed-at"}] ++ evict_runtime_ops()
        FiberDoc.write!(path, raw_fm, body, ops)
        {:ok, "parked #{fiber_id} (status: open) on session end\n"}
      end
    end
  end

  defp shuttle_block(%{"shuttle" => shuttle}) when is_map(shuttle), do: {:ok, shuttle}
  defp shuttle_block(_), do: {:error, "fiber has no shuttle: block"}

  # Awaiting, read straight from the document: `status: closed` with no verdict
  # (`tempered` unset). `tempered: false` (composted) and `tempered: true` are
  # termini, not awaiting. This is the sole accept/resume precondition — there
  # is no `review.state` to consult.
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

  defp require_pinned(%{"kind" => "pinned"}), do: :ok
  defp require_pinned(%{"mode" => "pinned"}), do: :ok

  defp require_pinned(shuttle),
    do:
      {:error,
       "park only applies to pinned roles (kind=#{inspect(Map.get(shuttle, "kind"))})"}

  defp require_schedule(%{"schedule" => schedule}) when is_map(schedule), do: {:ok, schedule}
  defp require_schedule(_), do: {:error, "fiber has no schedule"}

  # accept/resume/rearm all re-arm a role by writing `status: active` back to the
  # document — the sole dispatch gate (there is no enabled flag, no review
  # block). tempered and closed-at are deleted so the card leaves the
  # Awaiting/Tempered/Composted columns. Emitted as surgical edits against the
  # raw frontmatter text, NOT a re-serialization of the whole map: every other
  # key (notably the `outcome:` block scalar) stays byte-identical.
  #
  # The outcome is never blanked on re-arm: the last run's digest stays the card
  # headline until the next run overwrites it.
  defp rearm_ops do
    [{:put, "status", "active"}, {:delete, "tempered"}, {:delete, "closed-at"}]
  end

  # Drop the daemon-owned / legacy runtime keys from inside the `shuttle:` block.
  # Surgical: each is a {:delete_nested, "shuttle", key} that removes just that
  # child line (and its value span) if present, no-op if absent.
  defp evict_runtime_ops do
    Enum.map(@runtime_keys, &{:delete_nested, "shuttle", &1})
  end

  # Conclude the in-flight run by stamping `shuttle.handed_off_at = now` into the
  # block — folded into the SAME atomic re-arm write as `status: active`. A human
  # accept/resume/rearm declares the run concluded, which is exactly the signal a
  # clean worker exit leaves (`Shuttle.Continuation` reads `handed_off_at`), so
  # the standing-role dead-orphan detector sees a clean exit
  # (`handed_off_at >= dispatched_at`) and the cron lookback baseline advances.
  # This stops the temper oscillation with no separate re-arm field — the same
  # `handed_off_at` covers both the worker's clean exit and the human re-arm.
  defp conclude_run_op,
    do: {:put_nested, "shuttle", "handed_off_at", DateTime.to_iso8601(DateTime.utc_now())}
end
