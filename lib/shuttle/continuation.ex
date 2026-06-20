defmodule Shuttle.Continuation do
  @moduledoc """
  Worker-continuation signals, carried in the fiber's `shuttle:` frontmatter
  block — the substrate that replaced felt history (and, before this, the
  per-host marker files).

  Three runtime fields live under `shuttle:`, written at the two natural moments
  and read straight off the polled fiber map:

    * `shuttle.session_uuid` + `shuttle.dispatched_at` (+ `shuttle.run_id` for
      standing) — **written by the daemon at dispatch** (`write_dispatch/2`). The
      daemon holds the session UUID (claude: the `--session-id` it generated;
      codex/pi: scraped from the JSONL), so nothing is plumbed to the worker.
    * `shuttle.handed_off_at` — **written by the WORKER at clean exit** via
      `shuttle-ctl handoff` (Go, surgical `WriteBlock`), and by a human re-arm
      (`Shuttle.LifecycleStore`, which folds it into the same atomic re-arm
      write). A clean exit is the only thing that stamps it newer than the
      dispatch.

  The fields are **per-host by nature** but safe in git: only the owning host
  (`shuttle.host`) dispatches or resumes a fiber, so `session_uuid` is written
  and read by the same host; the git-sync to other hosts is inert (they ignore
  non-owned fibers). Reassigning `host` degrades gracefully to a failed resume →
  fresh.

  ## Continuation decision

  When a fiber's tmux session is gone, the daemon reads these fields off the
  freshly-polled fiber (no file IO — `felt show -j` already carries the whole
  `shuttle:` block):

    * `handed_off_at` present AND `handed_off_at >= dispatched_at` → **fresh**.
    * otherwise (dispatched, no newer handoff) → **resume `session_uuid`**.
    * absent `dispatched_at` → treat as **fresh** (safe default).

  A fresh `dispatched_at` at redispatch naturally supersedes a stale
  `handed_off_at` (the new dispatch is newer than the old handoff), so nothing
  needs clearing.

  Timestamps are **RFC3339 UTC**: the Elixir writer emits
  `DateTime.to_iso8601(DateTime.utc_now())` (`…Z`), the Go writer
  `time.Now().UTC().Format(time.RFC3339Nano)`; both parse identically via
  `DateTime.from_iso8601/1`, and the comparison is on the wire value, so
  sub-second precision is exact.
  """

  require Logger

  alias Shuttle.FiberDoc

  # ── readers (pure, over the polled fiber map) ────────────────────────────────

  @doc "The `shuttle:` block of a polled fiber map, or `%{}` when absent."
  @spec shuttle_block(map()) :: map()
  def shuttle_block(fiber) when is_map(fiber) do
    case Map.get(fiber, "shuttle") do
      block when is_map(block) -> block
      _ -> %{}
    end
  end

  @doc "`shuttle.dispatched_at` as a `DateTime`, or `nil` when absent/unparseable."
  @spec dispatched_at(map()) :: DateTime.t() | nil
  def dispatched_at(fiber), do: fiber |> shuttle_block() |> Map.get("dispatched_at") |> parse_iso()

  @doc "`shuttle.handed_off_at` as a `DateTime`, or `nil` when absent/unparseable."
  @spec handed_off_at(map()) :: DateTime.t() | nil
  def handed_off_at(fiber), do: fiber |> shuttle_block() |> Map.get("handed_off_at") |> parse_iso()

  @doc """
  The resumable session UUID — `shuttle.session_uuid`, or `nil` when absent/empty.
  The sole structured home for the resume id.
  """
  @spec resumable_session_id(map()) :: String.t() | nil
  def resumable_session_id(fiber) do
    case fiber |> shuttle_block() |> Map.get("session_uuid") do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  @doc """
  True iff the worker handed off cleanly since the last dispatch: `handed_off_at`
  exists and is `>= dispatched_at`. The autonomous fresh signal.

  Defaults to clean (true) when there is no `dispatched_at` — uncertainty never
  forces a surprising mid-transcript resume. With a `dispatched_at` but no newer
  `handed_off_at` → false (died mid-thought → resume).
  """
  @spec clean_handoff_since_dispatch?(map()) :: boolean()
  def clean_handoff_since_dispatch?(fiber) do
    case dispatched_at(fiber) do
      nil ->
        true

      dispatch_dt ->
        case handed_off_at(fiber) do
          nil -> false
          handoff_dt -> DateTime.compare(handoff_dt, dispatch_dt) != :lt
        end
    end
  end

  # ── writer (surgical frontmatter edit, keyed by fiber id) ────────────────────

  @doc """
  Stamp the dispatch fields into a fiber's `shuttle:` block:
  `{session_uuid, dispatched_at, run_id}`. `path` is the fiber's on-disk `.md`
  (the dispatcher carries `fiber["path"]` from the poll).

  `dispatched_at` is set to now (RFC3339 UTC) unless the caller supplied one.
  `session_uuid` is written only when non-empty (a codex/pi claim with no scraped
  UUID still stamps `dispatched_at`, the run-window anchor). `run_id` is written
  only when present (a plain oneshot omits it rather than writing `null`).

  Surgical and atomic via `Shuttle.FiberDoc`. Best-effort: a write failure is
  logged, not raised, so it can never block dispatch.
  """
  @spec write_dispatch(String.t(), map()) :: :ok | {:error, term()}
  def write_dispatch(path, fields)
      when is_binary(path) and path != "" and is_map(fields) do
    ops =
      [
        {:put_nested, "shuttle", "dispatched_at", Map.get(fields, :dispatched_at) || iso_now()}
      ]
      |> put_if(fields, :session_uuid)
      |> put_if(fields, :run_id)

    case FiberDoc.edit_path(path, ops) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.warning("Continuation: failed to stamp dispatch at #{path}: #{inspect(reason)}")
        err
    end
  end

  def write_dispatch(_path, _fields), do: :ok

  @doc """
  Stamp `shuttle.handed_off_at = now` into the fiber `.md` at `path` — the
  clean-exit signal, written surgically. The worker uses the Go path; this is the
  Elixir entry point (used by tests and any daemon-side conclude that is not
  already folded into a lifecycle re-arm write).
  """
  @spec mark_handed_off(String.t()) :: :ok | {:error, term()}
  def mark_handed_off(path) when is_binary(path) and path != "" do
    FiberDoc.edit_path(path, [{:put_nested, "shuttle", "handed_off_at", iso_now()}])
  end

  def mark_handed_off(_), do: :ok

  # ── internals ────────────────────────────────────────────────────────────────

  # Append a `{:put_nested, "shuttle", key, value}` op for an OPTIONAL field:
  # only when the caller supplied a non-nil, non-empty value. Keeps `session_uuid`
  # and `run_id` out of the block when there is nothing to write.
  defp put_if(ops, fields, key) do
    case Map.get(fields, key) do
      value when is_binary(value) and value != "" ->
        ops ++ [{:put_nested, "shuttle", to_string(key), value}]

      value when not is_nil(value) and not is_binary(value) ->
        ops ++ [{:put_nested, "shuttle", to_string(key), value}]

      _ ->
        ops
    end
  end

  defp iso_now, do: DateTime.to_iso8601(DateTime.utc_now())

  defp parse_iso(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_iso(_), do: nil
end
