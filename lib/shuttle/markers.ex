defmodule Shuttle.Markers do
  @moduledoc """
  Per-host runtime markers that carry Shuttle's worker-continuation signals —
  the substrate that replaced felt history.

  Two files per fiber, written by two disjoint writers so concurrent workers
  never contend, both under `$SHUTTLE_DATA_DIR` (default `~/.shuttle/`), keyed by
  the fiber's **runtime key** (uid when present, else slug — `runtime_key_for_fiber`):

    * `dispatch/<key>.json` — written by the DAEMON at dispatch.
      `{session_uuid, dispatched_at, run_id}`. Sole writer is the single OTP
      daemon process.
    * `handoff/<key>` — written by the WORKER at clean exit via
      `shuttle-ctl handoff`. `{at}` only. Sole writer is the one worker for the
      fiber. (Extensionless, matching the contract: the Go writer stamps the
      same key with no `.json` suffix.)

  Both writers use the IDENTICAL key. The daemon computes it
  (`runtime_key_for_fiber`) and plumbs it to the worker as `SHUTTLE_FIBER_KEY`,
  so the Go handoff writer and this Elixir reader never recompute it divergently
  — `dispatch/<key>` and `handoff/<key>` line up byte-for-byte.

  Timestamps are **RFC3339 UTC** (`DateTime.to_iso8601/1` on a UTC DateTime
  yields the `…Z` form, which Go's `time.RFC3339Nano` parses identically).
  Writes are atomic (write-temp-then-rename).

  ## Continuation decision

  When a fiber's tmux session is gone, the daemon reads both files:

    * `handoff` present AND `handoff.at >= dispatch.dispatched_at` → **fresh**.
    * otherwise (`dispatch` present, no newer handoff) → **resume
      `dispatch.session_uuid`**.
    * absent `dispatch` record → treat as **fresh** (safe default).

  The session_uuid for resume comes ONLY from the dispatch marker — the worker
  never knows its own UUID, the daemon does. This is the first time the
  structured resume path actually works (the documented `:runtime_session_id`
  opt was never supplied).
  """

  require Logger

  @doc """
  The Shuttle data dir (`$SHUTTLE_DATA_DIR`, else `~/.shuttle`). Matches the
  resolution the event-stream readers use (`WaitingTracker.default_events_file/0`,
  `SentFiles`) so every per-host artifact lands under the same root, and the Go
  CLI's writer resolves to the identical path.
  """
  @spec data_dir() :: String.t()
  def data_dir do
    System.get_env("SHUTTLE_DATA_DIR") ||
      Path.join(System.user_home!() || "/root", ".shuttle")
  end

  @doc "Absolute path of the dispatch marker for `key` (`dispatch/<key>.json`)."
  @spec dispatch_path(String.t()) :: String.t()
  def dispatch_path(key), do: Path.join([data_dir(), "dispatch", "#{key}.json"])

  @doc "Absolute path of the handoff marker for `key` (`handoff/<key>`, extensionless)."
  @spec handoff_path(String.t()) :: String.t()
  def handoff_path(key), do: Path.join([data_dir(), "handoff", key])

  @doc """
  Write the dispatch marker for `key`: `{session_uuid, dispatched_at, run_id}`.

  `dispatched_at` is stamped now (RFC3339 UTC). `run_id` is whatever the caller
  resolved (`nil` for a plain oneshot — JSON-encoded as `null`). Atomic
  (write-temp-then-rename). Best-effort: a write failure is logged, not raised,
  so it can never block dispatch.
  """
  @spec write_dispatch(String.t(), map()) :: :ok | {:error, term()}
  def write_dispatch(key, %{session_uuid: session_uuid} = fields)
      when is_binary(key) and key != "" do
    payload = %{
      session_uuid: session_uuid,
      dispatched_at: Map.get(fields, :dispatched_at) || iso_now(),
      run_id: Map.get(fields, :run_id)
    }

    write_json(dispatch_path(key), payload)
  end

  @doc """
  Read the dispatch marker for `key`, or `nil` when absent/unparseable.

  Returns a string-keyed map (`%{"session_uuid" => ..., "dispatched_at" => ...,
  "run_id" => ...}`).
  """
  @spec read_dispatch(String.t()) :: map() | nil
  def read_dispatch(key) when is_binary(key) and key != "" do
    read_json(dispatch_path(key))
  end

  def read_dispatch(_), do: nil

  @doc """
  Read the handoff marker for `key`, or `nil` when absent/unparseable.

  Returns `%{"at" => iso_string}`. The handoff marker carries no session_uuid —
  it is a pure clean-exit signal (the resume UUID lives in the dispatch marker).
  """
  @spec read_handoff(String.t()) :: map() | nil
  def read_handoff(key) when is_binary(key) and key != "" do
    read_json(handoff_path(key))
  end

  def read_handoff(_), do: nil

  @doc """
  Resolve `key`'s in-flight run by stamping its handoff marker (`{at}`, now).

  Called by the accept/resume/rearm lifecycle verbs. A human servicing the role
  *declares the run concluded* — which is exactly what a handoff marker means — so
  reusing the handoff marker (rather than a third, re-arm marker) keeps the model
  at two markers and makes both standing-role signals fall out for free:
    • the dead-orphan detector sees a clean exit (`handoff.at >= dispatch.at`), so
      a worker that died without handing off stops being re-marked awaiting on
      every reconcile (the temper oscillation), and
    • the cron lookback baseline advances (`last_service_event_ms` maxes over the
      handoff `at`), so the role isn't seen as due for a past occurrence.
  Both durable across a daemon restart. Best-effort: a write failure is logged.
  """
  @spec resolve(String.t()) :: :ok | {:error, term()}
  def resolve(key) when is_binary(key) and key != "" do
    write_json(handoff_path(key), %{at: iso_now()})
  end

  def resolve(_), do: :ok

  @doc """
  The `dispatched_at` of the dispatch marker for `key` as a `DateTime`, or `nil`.
  """
  @spec dispatched_at(String.t()) :: DateTime.t() | nil
  def dispatched_at(key) do
    with %{"dispatched_at" => iso} <- read_dispatch(key), do: parse_iso(iso)
  end

  @doc """
  The `at` of the handoff marker for `key` as a `DateTime`, or `nil`.
  """
  @spec handoff_at(String.t()) :: DateTime.t() | nil
  def handoff_at(key) do
    with %{"at" => iso} <- read_handoff(key), do: parse_iso(iso)
  end

  @doc """
  True iff the worker handed off cleanly since the last dispatch: a handoff
  marker exists with `at >= dispatch.dispatched_at`. The autonomous fresh signal.

  Defaults to clean (true) when there is no dispatch marker — uncertainty never
  forces a surprising mid-transcript resume. With a dispatch marker but no newer
  handoff → false (died mid-thought → resume).
  """
  @spec clean_handoff_since_dispatch?(String.t()) :: boolean()
  def clean_handoff_since_dispatch?(key) do
    case dispatched_at(key) do
      nil ->
        true

      dispatch_dt ->
        case handoff_at(key) do
          nil -> false
          handoff_dt -> DateTime.compare(handoff_dt, dispatch_dt) != :lt
        end
    end
  end

  @doc """
  The resumable session UUID for `key` — the dispatch marker's `session_uuid`, or
  `nil` when absent/empty. The sole structured home for the resume id.
  """
  @spec resumable_session_id(String.t()) :: String.t() | nil
  def resumable_session_id(key) do
    case read_dispatch(key) do
      %{"session_uuid" => uuid} when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  # ── internals ──

  defp iso_now, do: DateTime.to_iso8601(DateTime.utc_now())

  defp parse_iso(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_iso(_), do: nil

  defp write_json(path, payload) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         {:ok, json} <- Jason.encode(payload),
         tmp = path <> ".tmp.#{System.unique_integer([:positive])}",
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} = err ->
        Logger.warning("Markers: failed to write #{path}: #{inspect(reason)}")
        err
    end
  end

  defp read_json(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(raw) do
      map
    else
      _ -> nil
    end
  end
end
