defmodule Shuttle.WorkerWatcherTest do
  use ExUnit.Case

  alias Shuttle.WorkerWatcher
  alias Shuttle.Dispatcher

  # ── Mock Runner ──

  defmodule MockRunner do
    @behaviour Shuttle.Runner

    use Agent

    def start_link(_ \\ []) do
      Agent.start_link(fn -> %{sessions: MapSet.new()} end, name: __MODULE__)
    end

    def reset, do: Agent.update(__MODULE__, fn _ -> %{sessions: MapSet.new()} end)

    def add_session(s),
      do: Agent.update(__MODULE__, &%{&1 | sessions: MapSet.put(&1.sessions, s)})

    def remove_session(s),
      do: Agent.update(__MODULE__, &%{&1 | sessions: MapSet.delete(&1.sessions, s)})

    @impl true
    def cmd("tmux", ["has-session", "-t", session], _opts) do
      sessions = Agent.get(__MODULE__, & &1.sessions)

      if MapSet.member?(sessions, session) do
        {"", 0}
      else
        {"can't find session", 1}
      end
    end

    def cmd(_, _, _), do: {"", 0}
  end

  # ── Flakey Runner ──
  # Like MockRunner but supports injecting N transient failures: the next N
  # `tmux has-session` calls return non-zero even if the session is alive.
  # Used to test that the watcher tolerates transient check failures without
  # prematurely declaring the worker dead.

  defmodule FlakeyRunner do
    @behaviour Shuttle.Runner

    use Agent

    def start_link(_ \\ []) do
      Agent.start_link(
        fn -> %{sessions: MapSet.new(), inject_failures: 0} end,
        name: __MODULE__
      )
    end

    def reset,
      do: Agent.update(__MODULE__, fn _ -> %{sessions: MapSet.new(), inject_failures: 0} end)

    def add_session(s),
      do: Agent.update(__MODULE__, &%{&1 | sessions: MapSet.put(&1.sessions, s)})

    def remove_session(s),
      do: Agent.update(__MODULE__, &%{&1 | sessions: MapSet.delete(&1.sessions, s)})

    # Make the next `n` tmux has-session calls return non-zero regardless
    # of session state. Once the counter is exhausted, normal behaviour resumes.
    def inject_failures(n),
      do: Agent.update(__MODULE__, &%{&1 | inject_failures: n})

    @impl true
    def cmd("tmux", ["has-session", "-t", session], _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        cond do
          state.inject_failures > 0 ->
            # Transient failure: return non-zero even if the session is alive.
            {{"transient tmux error", 1}, %{state | inject_failures: state.inject_failures - 1}}

          MapSet.member?(state.sessions, session) ->
            {{"", 0}, state}

          true ->
            {{"can't find session", 1}, state}
        end
      end)
    end

    def cmd(_, _, _), do: {"", 0}
  end

  # ── Setup ──

  setup do
    start_supervised!(MockRunner)
    start_supervised!(FlakeyRunner)
    MockRunner.reset()
    FlakeyRunner.reset()
    :ok
  end

  # ── Tests ──

  test "watcher detects session death and notifies poller" do
    session = Dispatcher.session_name("tests/haiku")
    MockRunner.add_session(session)

    {:ok, watcher} =
      WorkerWatcher.start_link(
        fiber_id: "tests/haiku",
        session: session,
        poller: self(),
        runner: MockRunner,
        heartbeat_interval_ms: 50
      )

    # Wait for a few heartbeats
    Process.sleep(120)

    # Session still alive — no exit message
    refute_receive {:worker_exited, _, _, _}, 50

    # Kill the session
    MockRunner.remove_session(session)
    Process.sleep(120)

    # Should receive exit notification
    assert_receive {:worker_exited, "tests/haiku", :normal_exit, false}, 200

    # Watcher should have stopped
    refute Process.alive?(watcher)
  end

  test "watcher exits immediately if session does not exist on init" do
    assert {:error, :normal} =
             WorkerWatcher.start_link(
               fiber_id: "tests/missing",
               session: Dispatcher.session_name("tests/missing"),
               poller: self(),
               runner: MockRunner,
               heartbeat_interval_ms: 50
             )

    assert_receive {:worker_exited, "tests/missing", :session_not_found, _}, 200
  end

  test "watcher can be stopped gracefully" do
    session = Dispatcher.session_name("tests/haiku")
    MockRunner.add_session(session)

    {:ok, watcher} =
      WorkerWatcher.start_link(
        fiber_id: "tests/haiku",
        session: session,
        poller: self(),
        runner: MockRunner,
        heartbeat_interval_ms: 50
      )

    assert Process.alive?(watcher)
    WorkerWatcher.stop(watcher)
    Process.sleep(50)
    refute Process.alive?(watcher)
  end

  # ── Flake robustness tests ─────────────────────────────────────────────────
  # Suspect 4 in finding-ghost-workers-stuck-running: a transient non-zero exit
  # from `tmux has-session` currently terminates the watcher prematurely, leaving
  # the fiber orphaned in the daemon's running set with no future cleanup.
  # The desired behaviour: tolerate up to max_consecutive_failures transient
  # failures before declaring the worker dead.

  test "watcher survives transient tmux failures without declaring worker dead" do
    session = Dispatcher.session_name("tests/flaky")
    FlakeyRunner.add_session(session)

    {:ok, watcher} =
      WorkerWatcher.start_link(
        fiber_id: "tests/flaky",
        session: session,
        poller: self(),
        runner: FlakeyRunner,
        heartbeat_interval_ms: 50,
        # 3 consecutive failures required to declare the worker dead.
        max_consecutive_failures: 3
      )

    # Inject 2 transient failures — below the threshold of 3.
    # The session is still alive in FlakeyRunner.sessions.
    FlakeyRunner.inject_failures(2)

    # Wait for those 2 failures to be consumed (≥ 2 × 50ms heartbeats).
    Process.sleep(200)

    # Watcher should NOT have exited: 2 < max_consecutive_failures.
    refute_receive {:worker_exited, _, _, _}, 50
    assert Process.alive?(watcher)

    # Now truly remove the session (sustained failure).
    FlakeyRunner.remove_session(session)

    # Wait for max_consecutive_failures × heartbeat_interval to elapse.
    Process.sleep(300)

    # Now the watcher should declare the worker dead.
    assert_receive {:worker_exited, "tests/flaky", :normal_exit, false}, 200
    refute Process.alive?(watcher)
  end

  test "watcher resets failure counter after recovery" do
    session = Dispatcher.session_name("tests/recover")
    FlakeyRunner.add_session(session)

    {:ok, watcher} =
      WorkerWatcher.start_link(
        fiber_id: "tests/recover",
        session: session,
        poller: self(),
        runner: FlakeyRunner,
        heartbeat_interval_ms: 50,
        max_consecutive_failures: 3
      )

    # Inject 2 transient failures, then let it recover.
    FlakeyRunner.inject_failures(2)
    Process.sleep(250)

    # Still alive after 2 failures and recovery.
    refute_receive {:worker_exited, _, _, _}, 50
    assert Process.alive?(watcher)

    # Now inject 2 more failures — the counter must have reset to 0 after
    # the recovery, so 2 < 3 is still safe.
    FlakeyRunner.inject_failures(2)
    Process.sleep(250)

    refute_receive {:worker_exited, _, _, _}, 50
    assert Process.alive?(watcher)

    # Sustained failure: remove session so all future checks fail.
    FlakeyRunner.remove_session(session)
    Process.sleep(300)

    assert_receive {:worker_exited, "tests/recover", :normal_exit, false}, 200
    refute Process.alive?(watcher)
  end
end
