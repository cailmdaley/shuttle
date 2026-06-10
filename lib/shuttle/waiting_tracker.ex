defmodule Shuttle.WaitingTracker do
  @moduledoc """
  Tracks which worker sessions are *waiting for human input* by tailing this
  host's Claude Code hook-event stream (`~/.portolan/data/events.jsonl`).

  ## Why tail the local stream

  Claude Code's `Notification` hook fires exactly when an agent blocks on a
  human — a permission prompt or an idle "waiting for your input" notice — and
  `~/loom/hooks/portolan-hook.sh` already appends every hook event to a
  host-local `events.jsonl` on every machine a worker runs on. The owning
  daemon stamps runtime liveness for *its own* fibers (local daemon for local
  workers, the remote daemon for remote workers — the resolve/invoke split in
  the composite feed). So the simplest transport that respects that split is:
  **each daemon tails its own host's `events.jsonl`** and contributes a
  `phase: "waiting"` to the runtime block it already serves. No new cross-host
  channel — the waiting signal rides the same per-host runtime stamping that
  `tmux_session` liveness already does.

  ## State machine (per tmux session)

    * a `notification` event → the session is marked waiting
    * *any other* event from that session (tool use, `user_prompt_submit`,
      `stop`, `session_end`, …) → the session is cleared

  Self-healing falls out of two things: clear-on-activity above, and the fact
  that `Shuttle.Poller.stamp_runtime/2` only stamps `phase: "waiting"` for
  sessions that are *still in `state.running`*. A dead worker is gone from
  `running`, so no stale "waiting" badge can survive its session. A periodic
  age prune (`@max_age_ms`) is pure hygiene for the rare session that goes
  waiting and then dies without emitting a clearing event.

  ## Reading the past

  On boot the tail offset is set to the file's current end — historical
  notifications are not replayed, so a daemon restart can't resurrect a stale
  waiting state from an old line.

  Only `*-shuttle` sessions are tracked; events from interactive (non-shuttle)
  sessions are ignored, mirroring the dispatch gate.
  """

  use GenServer
  require Logger

  @poll_interval_ms 1_000
  @max_age_ms 6 * 60 * 60 * 1_000
  @shuttle_session_suffix "-shuttle"

  defmodule State do
    @moduledoc false
    defstruct [:events_file, :poll_interval_ms, offset: 0, waiting: %{}]
  end

  # ── Client ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The set of tmux session names currently waiting for human input.

  Returns a `MapSet` so `stamp_runtime` can membership-test each running
  worker's session in O(1). Defaults to the singleton tracker; pass a pid/name
  for tests.
  """
  @spec waiting_sessions(GenServer.server()) :: MapSet.t()
  def waiting_sessions(server \\ __MODULE__) do
    GenServer.call(server, :waiting_sessions)
  catch
    :exit, _ -> MapSet.new()
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

    # Start at end-of-file so a restart doesn't replay historical notifications.
    offset =
      case File.stat(events_file) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end

    schedule_poll(poll_interval_ms)
    {:ok, %State{events_file: events_file, poll_interval_ms: poll_interval_ms, offset: offset}}
  end

  @impl true
  def handle_call(:waiting_sessions, _from, state) do
    {:reply, MapSet.new(Map.keys(state.waiting)), state}
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
            waiting = Enum.reduce(String.split(chunk, "\n", trim: true), state.waiting, &apply_event/2)
            %{state | offset: size, waiting: waiting}

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

  defp apply_event(line, waiting) do
    case Jason.decode(line) do
      {:ok, %{"type" => type, "tmuxSession" => session}}
      when is_binary(session) and session != "" ->
        if shuttle_session?(session) do
          if type == "notification" do
            Map.put(waiting, session, now_ms())
          else
            Map.delete(waiting, session)
          end
        else
          waiting
        end

      _ ->
        waiting
    end
  end

  defp prune_stale(%State{waiting: waiting} = state) do
    cutoff = now_ms() - @max_age_ms
    %{state | waiting: Map.reject(waiting, fn {_s, at} -> at < cutoff end)}
  end

  defp shuttle_session?(session), do: String.ends_with?(session, @shuttle_session_suffix)

  defp now_ms, do: System.system_time(:millisecond)

  defp home, do: System.user_home!() || "/root"
end
