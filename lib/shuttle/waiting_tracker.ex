defmodule Shuttle.WaitingTracker do
  @moduledoc """
  Tracks which worker sessions are *waiting for a human* by tailing this host's
  Claude Code hook-event stream (`~/.portolan/data/events.jsonl`) and deriving
  two polled phases — `waiting` and `attention` — from it.

  ## Why tail the local stream

  `~/loom/hooks/portolan-hook.sh` already appends every Claude Code hook event
  to a host-local `events.jsonl` on every machine a worker runs on. The owning
  daemon stamps runtime liveness for *its own* fibers (local daemon for local
  workers, the remote daemon for remote workers — the resolve/invoke split in
  the composite feed). So the simplest transport that respects that split is:
  **each daemon tails its own host's `events.jsonl`** and contributes a
  `phase` to the runtime block it already serves. No new cross-host channel —
  the waiting signal rides the same per-host runtime stamping that
  `tmux_session` liveness already does.

  ## State machine (per `*-shuttle` tmux session)

  Each tracked session holds at most one entry — a `%{kind: ..., since: ms}`
  where `kind` is `:stopped` or `:attention`. The transition on each event:

    * `notification` → mark `:attention` with `since: now` (always overwrites,
      even an existing `:stopped`). This is the *escalation* signal — the
      built-in Claude Code Notification hook fires when an agent blocks on a
      human (idle prompt, permission, MCP elicitation). It is the **only**
      escalation source.
    * `stop` → STICKY mark `:stopped`. If the entry is already `:attention`,
      leave it untouched (a turn finishing must not downgrade an escalation).
      If it is already `:stopped`, keep its original `since` (do not reset the
      gate clock). If absent, put `:stopped` with `since: now`.
    * *any other* event — `subagent_stop`, `user_prompt_submit`,
      `pre_tool_use`, `post_tool_use`, `session_start`, `session_end`, … →
      clear the entry. `subagent_stop` clears (not marks): a subagent finishing
      means the main agent is mid-orchestration, i.e. busy.

  ## Two phases, gated at READ time

  `waiting_phases/1` resolves the stored kinds to a `session => phase` string
  map *with the current clock*, so the value can flip purely by elapsed time
  without a new event:

    * `:attention` → always `"attention"` (no gate — escalation is immediate).
    * `:stopped` → `"waiting"` only once it has persisted `@stopped_gate_ms`
      (60s); before the gate matures the session is omitted entirely, so an
      autonomous worker pausing between turns doesn't flash a chip.

  Self-healing falls out of clear-on-activity above plus the fact that
  `Shuttle.Poller.stamp_runtime/2` only stamps a phase for sessions still in
  `state.running` — a dead worker is gone from `running`, so no stale badge can
  survive its session. A periodic age prune (`@max_age_ms`) is hygiene for the
  rare session that marks and then dies without emitting a clearing event.

  ## Reading the past

  On boot the tail offset is set to the file's current end — historical events
  are not replayed, so a daemon restart can't resurrect a stale state from an
  old line.

  Only `*-shuttle` sessions are tracked; events from interactive (non-shuttle)
  sessions are ignored, mirroring the dispatch gate.
  """

  use GenServer
  require Logger

  @poll_interval_ms 1_000
  @max_age_ms 6 * 60 * 60 * 1_000
  @stopped_gate_ms 60_000
  @shuttle_session_suffix "-shuttle"

  defmodule State do
    @moduledoc false
    # `waiting` is `session => %{kind: :stopped | :attention, since: ms}`.
    # `clock` is a 0-arity fn returning the current epoch ms (injectable for tests).
    defstruct [:events_file, :poll_interval_ms, :clock, offset: 0, waiting: %{}]
  end

  # ── Client ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  A `session => phase` map for the tmux sessions currently signalling a human,
  resolved at call time against the tracker's clock.

  `phase` is `"attention"` (escalation, immediate) or `"waiting"` (baseline,
  only after the 60s gate matures). Sessions with no mature signal are omitted,
  so `stamp_runtime` can look up each running worker's session in O(1) and treat
  absence as "busy". Defaults to the singleton tracker; pass a pid/name for tests.
  """
  @spec waiting_phases(GenServer.server(), pos_integer() | nil) ::
          %{optional(String.t()) => String.t()}
  def waiting_phases(server \\ __MODULE__, now \\ nil) do
    GenServer.call(server, {:waiting_phases, now})
  catch
    :exit, _ -> %{}
  end

  @doc "Default host-local events stream path, honoring the same env the hook reads."
  def default_events_file do
    System.get_env("PORTOLAN_EVENTS_FILE") ||
      Path.join(
        System.get_env("PORTOLAN_DATA_DIR") || Path.join(home(), ".portolan/data"),
        "events.jsonl"
      )
  end

  # ── Server ──

  @impl true
  def init(opts) do
    events_file = Keyword.get(opts, :events_file, default_events_file())
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)
    clock = Keyword.get(opts, :clock, &default_clock/0)

    # Start at end-of-file so a restart doesn't replay historical events.
    offset =
      case File.stat(events_file) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end

    schedule_poll(poll_interval_ms)

    {:ok,
     %State{
       events_file: events_file,
       poll_interval_ms: poll_interval_ms,
       clock: clock,
       offset: offset
     }}
  end

  @impl true
  def handle_call({:waiting_phases, now_override}, _from, state) do
    now = now_override || now_ms(state)

    phases =
      Enum.reduce(state.waiting, %{}, fn {session, %{kind: kind, since: since}}, acc ->
        case kind do
          :attention -> Map.put(acc, session, "attention")
          :stopped when now - since >= @stopped_gate_ms -> Map.put(acc, session, "waiting")
          :stopped -> acc
        end
      end)

    {:reply, phases, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = state |> ingest_new_lines() |> prune_stale()
    schedule_poll(state.poll_interval_ms)
    {:noreply, state}
  end

  defp schedule_poll(ms), do: Process.send_after(self(), :poll, ms)

  # Read bytes appended since the last offset; reset to 0 if the file shrank
  # (truncation / rotation). A missing file leaves state untouched.
  defp ingest_new_lines(%State{events_file: path, offset: offset} = state) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > offset ->
        case read_range(path, offset, size - offset) do
          {:ok, chunk} ->
            # Consume only up to the last newline; a trailing partial line (a
            # record still being written) is left unconsumed so the next poll
            # re-reads it whole. Advancing past it would silently drop the event.
            case :binary.matches(chunk, "\n") do
              [] ->
                state

              matches ->
                {last_nl, _} = List.last(matches)
                consumed = last_nl + 1
                complete = binary_part(chunk, 0, consumed)
                now = now_ms(state)

                waiting =
                  Enum.reduce(
                    String.split(complete, "\n", trim: true),
                    state.waiting,
                    &apply_event(&1, &2, now)
                  )

                %{state | offset: offset + consumed, waiting: waiting}
            end

          _ ->
            state
        end

      {:ok, %{size: size}} when size < offset ->
        %{state | offset: size}

      _ ->
        state
    end
  end

  defp read_range(path, offset, length) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        :file.position(file, offset)
        case :file.read(file, length) do
          {:ok, data} -> {:ok, data}
          other -> other
        end
      after
        File.close(file)
      end
    end
  end

  defp apply_event(line, waiting, now) do
    case Jason.decode(line) do
      {:ok, %{"type" => type, "tmuxSession" => session}}
      when is_binary(session) and session != "" ->
        if shuttle_session?(session) do
          transition(waiting, session, type, now)
        else
          waiting
        end

      _ ->
        waiting
    end
  end

  # `notification` always escalates to `:attention` (overwrites any prior kind).
  # `stop` is STICKY: it never downgrades an `:attention`, and it preserves an
  # existing `:stopped`'s `since` so the 60s gate clock isn't reset by repeated
  # stops; only an absent entry gets a fresh `:stopped`. Every other event type
  # (including `subagent_stop`) is activity and clears the entry.
  defp transition(waiting, session, "notification", now),
    do: Map.put(waiting, session, %{kind: :attention, since: now})

  defp transition(waiting, session, "stop", now) do
    case Map.get(waiting, session) do
      %{kind: :attention} = entry -> Map.put(waiting, session, entry)
      %{kind: :stopped} = entry -> Map.put(waiting, session, entry)
      _ -> Map.put(waiting, session, %{kind: :stopped, since: now})
    end
  end

  defp transition(waiting, session, _other, _now), do: Map.delete(waiting, session)

  defp prune_stale(%State{waiting: waiting} = state) do
    cutoff = now_ms(state) - @max_age_ms
    %{state | waiting: Map.reject(waiting, fn {_s, entry} -> entry.since < cutoff end)}
  end

  defp shuttle_session?(session), do: String.ends_with?(session, @shuttle_session_suffix)

  defp now_ms(%State{clock: clock}) when is_function(clock, 0), do: clock.()
  defp now_ms(%State{}), do: default_clock()

  defp default_clock, do: System.system_time(:millisecond)

  defp home, do: System.user_home!() || "/root"
end
