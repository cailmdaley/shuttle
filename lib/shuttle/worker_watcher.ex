defmodule Shuttle.WorkerWatcher do
  @moduledoc """
  Per-worker GenServer that tracks tmux session liveness from the outside.

  One watcher per dispatched worker. The watcher periodically checks
  `tmux has-session` and reports back to the Poller when the session dies.

  The watcher is the supervised unit; tmux owns the actual worker process.
  See SPEC §9 for the tmux-watcher architecture.
  """

  use GenServer
  require Logger

  @default_heartbeat_interval_ms 5_000
  @default_max_consecutive_failures 3

  # ── Client ──

  @doc """
  Starts a watcher for the given fiber and tmux session.

  Options:
    * `:fiber_id` — required. The fiber being watched.
    * `:session` — required. The tmux session name (e.g. "shuttle-tests/haiku").
    * `:poller` — required. The pid of the Poller GenServer to notify on exit.
    * `:runner` — module implementing `Shuttle.Runner` behavior. Defaults to `Shuttle.Runner.Default`.
    * `:heartbeat_interval_ms` — interval between tmux liveness checks. Default 5_000.
    * `:max_consecutive_failures` — how many consecutive non-zero exits from
      `tmux has-session` are tolerated before declaring the worker dead. Protects
      against transient tmux hiccups (suspect 4 in ghost-workers bug). Default 3,
      which means a truly dead session is detected within `3 × heartbeat_interval_ms`.
    * `:token_budget` — optional per-worker token cap.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stops the watcher gracefully.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # ── Server ──

  @impl true
  def init(opts) do
    fiber_id = Keyword.fetch!(opts, :fiber_id)
    session = Keyword.fetch!(opts, :session)
    poller = Keyword.fetch!(opts, :poller)
    runner = Keyword.get(opts, :runner, Shuttle.Runner.Default)
    heartbeat_interval = Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms)
    max_consecutive_failures = Keyword.get(opts, :max_consecutive_failures, @default_max_consecutive_failures)
    token_budget = Keyword.get(opts, :token_budget)

    now = DateTime.utc_now()

    state = %{
      fiber_id: fiber_id,
      session: session,
      poller: poller,
      runner: runner,
      heartbeat_interval_ms: heartbeat_interval,
      max_consecutive_failures: max_consecutive_failures,
      consecutive_failures: 0,
      heartbeat_timer_ref: nil,
      started_at: now,
      last_activity_at: now,
      tokens_used: 0,
      token_budget: token_budget
    }

    # On init, check if the session exists. If not, exit immediately.
    case check_session(state) do
      :alive ->
        ref = Process.send_after(self(), :heartbeat, heartbeat_interval)
        {:ok, %{state | heartbeat_timer_ref: ref}}

      :dead ->
        notify_poller(state, :session_not_found)
        {:stop, :normal}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    case check_session(state) do
      :alive ->
        ref = Process.send_after(self(), :heartbeat, state.heartbeat_interval_ms)

        {:noreply,
         %{state | heartbeat_timer_ref: ref, last_activity_at: DateTime.utc_now(), consecutive_failures: 0}}

      :dead ->
        failures = state.consecutive_failures + 1

        if failures >= state.max_consecutive_failures do
          Logger.info("Worker session ended: fiber_id=#{state.fiber_id} session=#{state.session}")
          notify_poller(state, :normal_exit)
          {:stop, :normal, state}
        else
          Logger.debug(
            "Heartbeat: transient tmux check failure #{failures}/#{state.max_consecutive_failures} " <>
              "for #{state.fiber_id} — will retry"
          )

          ref = Process.send_after(self(), :heartbeat, state.heartbeat_interval_ms)
          {:noreply, %{state | heartbeat_timer_ref: ref, consecutive_failures: failures}}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    if is_reference(state.heartbeat_timer_ref) do
      Process.cancel_timer(state.heartbeat_timer_ref)
    end

    :ok
  end

  # ── Internal ──

  defp check_session(state) do
    case state.runner.cmd("tmux", ["has-session", "-t", state.session], stderr_to_stdout: true) do
      {_, 0} -> :alive
      {_, _} -> :dead
    end
  end

  defp notify_poller(state, reason) do
    send(state.poller, {:worker_exited, state.fiber_id, reason, session_alive?(state)})
  end

  defp session_alive?(state) do
    case state.runner.cmd("tmux", ["has-session", "-t", state.session], stderr_to_stdout: true) do
      {_, 0} -> true
      {_, _} -> false
    end
  end
end
