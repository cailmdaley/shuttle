defmodule Shuttle.WorkerWatcherTest do
  use ExUnit.Case

  alias Shuttle.WorkerWatcher

  # ── Mock Runner ──

  defmodule MockRunner do
    @behaviour Shuttle.Runner

    use Agent

    def start_link(_ \\ []) do
      Agent.start_link(fn -> %{sessions: MapSet.new()} end, name: __MODULE__)
    end

    def reset, do: Agent.update(__MODULE__, fn _ -> %{sessions: MapSet.new()} end)
    def add_session(s), do: Agent.update(__MODULE__, &%{&1 | sessions: MapSet.put(&1.sessions, s)})
    def remove_session(s), do: Agent.update(__MODULE__, &%{&1 | sessions: MapSet.delete(&1.sessions, s)})

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

  # ── Setup ──

  setup do
    start_supervised!(MockRunner)
    MockRunner.reset()
    :ok
  end

  # ── Tests ──

  test "watcher detects session death and notifies poller" do
    MockRunner.add_session("shuttle-tests-haiku")

    {:ok, watcher} = WorkerWatcher.start_link(
      fiber_id: "tests/haiku",
      session: "shuttle-tests-haiku",
      poller: self(),
      runner: MockRunner,
      heartbeat_interval_ms: 50
    )

    # Wait for a few heartbeats
    Process.sleep(120)

    # Session still alive — no exit message
    refute_receive {:worker_exited, _, _, _}, 50

    # Kill the session
    MockRunner.remove_session("shuttle-tests-haiku")
    Process.sleep(120)

    # Should receive exit notification
    assert_receive {:worker_exited, "tests/haiku", :normal_exit, false}, 200

    # Watcher should have stopped
    refute Process.alive?(watcher)
  end

  test "watcher exits immediately if session does not exist on init" do
    assert {:error, :normal} = WorkerWatcher.start_link(
      fiber_id: "tests/missing",
      session: "shuttle-tests-missing",
      poller: self(),
      runner: MockRunner,
      heartbeat_interval_ms: 50
    )

    assert_receive {:worker_exited, "tests/missing", :session_not_found, _}, 200
  end

  test "watcher can be stopped gracefully" do
    MockRunner.add_session("shuttle-tests-haiku")

    {:ok, watcher} = WorkerWatcher.start_link(
      fiber_id: "tests/haiku",
      session: "shuttle-tests-haiku",
      poller: self(),
      runner: MockRunner,
      heartbeat_interval_ms: 50
    )

    assert Process.alive?(watcher)
    WorkerWatcher.stop(watcher)
    Process.sleep(50)
    refute Process.alive?(watcher)
  end
end
