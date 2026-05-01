defmodule Shuttle.PollerTest do
  use ExUnit.Case

  alias Shuttle.Poller

  # ── Mock Runner ──

  defmodule MockRunner do
    @behaviour Shuttle.Runner

    use Agent

    def start_link(_ \\ []) do
      Agent.start_link(fn -> %{
        commands: [],
        tmux_sessions: MapSet.new(),
        fibers: %{},
        felt_ls: []
      } end, name: __MODULE__)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{
        commands: [],
        tmux_sessions: MapSet.new(),
        fibers: %{},
        felt_ls: []
      } end)
    end

    def set_fiber(id, fiber), do: Agent.update(__MODULE__, &put_in(&1.fibers[id], fiber))
    def set_felt_ls(fibers), do: Agent.update(__MODULE__, &%{&1 | felt_ls: fibers})
    def add_tmux_session(session), do: Agent.update(__MODULE__, &%{&1 | tmux_sessions: MapSet.put(&1.tmux_sessions, session)})
    def remove_tmux_session(session), do: Agent.update(__MODULE__, &%{&1 | tmux_sessions: MapSet.delete(&1.tmux_sessions, session)})
    def commands, do: Agent.get(__MODULE__, & &1.commands)

    @impl true
    def cmd(command, args, _opts) do
      Agent.update(__MODULE__, fn state ->
        %{state | commands: state.commands ++ [{command, args}]}
      end)

      full_args = Enum.join(args, " ")

      cond do
        command == "felt" and String.contains?(full_args, "ls") ->
          fibers = Agent.get(__MODULE__, & &1.felt_ls)
          {Jason.encode!(fibers), 0}

        command == "felt" and String.contains?(full_args, "show") ->
          fiber_id = extract_fiber_id(args)
          fibers = Agent.get(__MODULE__, & &1.fibers)

          case Map.get(fibers, fiber_id) do
            nil -> {"fiber not found", 1}
            fiber -> {Jason.encode!(fiber), 0}
          end

        command == "tmux" and hd(args) == "has-session" ->
          session = Enum.at(args, 2)
          sessions = Agent.get(__MODULE__, & &1.tmux_sessions)

          if MapSet.member?(sessions, session) do
            {"", 0}
          else
            {"can't find session", 1}
          end

        command == "tmux" and hd(args) == "new-session" ->
          session = Enum.at(args, 3)
          add_tmux_session(session)
          {"", 0}

        command == "tmux" and hd(args) == "kill-session" ->
          session = Enum.at(args, 2)
          remove_tmux_session(session)
          {"", 0}

        command == "tmux" and hd(args) == "ls" ->
          sessions = Agent.get(__MODULE__, & &1.tmux_sessions)
          output = sessions |> MapSet.to_list() |> Enum.join("\n")
          {output, 0}

        true ->
          {"", 0}
      end
    end

    defp extract_fiber_id(args) do
      # args like ["show", "tests/haiku", "--json"]
      Enum.find(args, "", fn arg -> arg != "show" and arg != "--json" end)
    end
  end

  # ── Setup ──

  setup do
    start_supervised!(MockRunner)
    MockRunner.reset()
    :ok
  end

  # ── Helpers ──

  defp make_fiber(id, attrs \\ %{}) do
    Map.merge(%{
      "id" => id,
      "name" => id,
      "status" => "active",
      "tags" => ["constitution"],
      "created_at" => "2026-04-28T00:00:00Z"
    }, attrs)
  end

  # ── Tests ──

  test "poller discovers and dispatches eligible fibers" do
    fiber = make_fiber("tests/haiku")
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/haiku", fiber)

    {:ok, poller} = Poller.start_link(
      name: :test_poller_1,
      runner: MockRunner,
      poll_interval_ms: 60_000,
      felt_host: "/tmp"
    )

    # Trigger a poll cycle manually
    send(poller, {:tick, Poller.snapshot(poller) |> Map.get(:tick_token)})
    # Wait for async dispatch
    Process.sleep(100)

    # Check that tmux new-session was called
    commands = MockRunner.commands()
    assert Enum.any?(commands, fn {cmd, args} ->
      cmd == "tmux" and hd(args) == "new-session"
    end)

    # Check snapshot shows running worker
    snap = Poller.snapshot(poller)
    assert length(snap.eligible) == 1
    assert hd(snap.eligible).fiber_id == "tests/haiku"
  end

  test "poller skips closed fibers" do
    fiber = make_fiber("tests/closed", %{"status" => "closed"})
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/closed", fiber)

    {:ok, poller} = Poller.start_link(
      name: :test_poller_2,
      runner: MockRunner,
      poll_interval_ms: 60_000,
      felt_host: "/tmp"
    )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    commands = MockRunner.commands()
    refute Enum.any?(commands, fn {cmd, args} ->
      cmd == "tmux" and hd(args) == "new-session"
    end)
  end

  test "poller skips draft fibers" do
    fiber = make_fiber("tests/draft", %{"tags" => ["constitution", "draft"]})
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/draft", fiber)

    {:ok, poller} = Poller.start_link(
      name: :test_poller_3,
      runner: MockRunner,
      poll_interval_ms: 60_000,
      felt_host: "/tmp"
    )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    commands = MockRunner.commands()
    refute Enum.any?(commands, fn {cmd, args} ->
      cmd == "tmux" and hd(args) == "new-session"
    end)
  end

  test "poller respects dependency satisfaction" do
    dep = make_fiber("tests/dep", %{"tempered" => false, "tags" => []})
    fiber = make_fiber("tests/dependent", %{"depends_on" => ["tests/dep"]})

    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/dependent", fiber)
    MockRunner.set_fiber("tests/dep", dep)

    {:ok, poller} = Poller.start_link(
      name: :test_poller_4,
      runner: MockRunner,
      poll_interval_ms: 60_000,
      felt_host: "/tmp"
    )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    commands = MockRunner.commands()
    refute Enum.any?(commands, fn {cmd, args} ->
      cmd == "tmux" and hd(args) == "new-session" and Enum.member?(args, "shuttle-tests/dependent")
    end)
  end

  test "poller dispatches when dependencies are tempered" do
    dep = make_fiber("tests/dep", %{"tempered" => true})
    fiber = make_fiber("tests/dependent", %{"depends_on" => ["tests/dep"]})

    MockRunner.set_felt_ls([fiber, dep])
    MockRunner.set_fiber("tests/dependent", fiber)
    MockRunner.set_fiber("tests/dep", dep)

    {:ok, poller} = Poller.start_link(
      name: :test_poller_5,
      runner: MockRunner,
      poll_interval_ms: 60_000,
      felt_host: "/tmp"
    )

    send(poller, :run_poll_cycle)
    Process.sleep(100)

    commands = MockRunner.commands()
    assert Enum.any?(commands, fn {cmd, args} ->
      cmd == "tmux" and hd(args) == "new-session"
    end)
  end

  test "poller does not double-dispatch" do
    fiber = make_fiber("tests/haiku")
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/haiku", fiber)
    MockRunner.add_tmux_session("shuttle-tests/haiku")

    {:ok, poller} = Poller.start_link(
      name: :test_poller_6,
      runner: MockRunner,
      poll_interval_ms: 60_000,
      felt_host: "/tmp"
    )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    # Should not create a new session
    new_session_count =
      MockRunner.commands()
      |> Enum.filter(fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)
      |> length()

    assert new_session_count == 0
  end

  test "poller schedules retry when worker exits and fiber still active" do
    fiber = make_fiber("tests/haiku")
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/haiku", fiber)

    {:ok, poller} = Poller.start_link(
      name: :test_poller_7,
      runner: MockRunner,
      poll_interval_ms: 60_000,
      felt_host: "/tmp"
    )

    # Dispatch
    send(poller, :run_poll_cycle)
    Process.sleep(100)

    snap1 = Poller.snapshot(poller)
    assert length(snap1.eligible) == 1

    # Simulate worker exit (tmux session dies)
    MockRunner.remove_tmux_session("shuttle-tests/haiku")
    send(poller, {:worker_exited, "tests/haiku", :normal_exit, false})
    Process.sleep(50)

    snap2 = Poller.snapshot(poller)
    assert length(snap2.eligible) == 0
    assert length(snap2.retrying) == 1
    assert hd(snap2.retrying).fiber_id == "tests/haiku"
  end

  test "poller releases claim when worker exits and fiber is closed" do
    fiber = make_fiber("tests/haiku")
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/haiku", fiber)

    {:ok, poller} = Poller.start_link(
      name: :test_poller_8,
      runner: MockRunner,
      poll_interval_ms: 60_000,
      felt_host: "/tmp"
    )

    # Dispatch
    send(poller, :run_poll_cycle)
    Process.sleep(100)

    # Close the fiber
    MockRunner.set_fiber("tests/haiku", %{fiber | "status" => "closed"})
    MockRunner.remove_tmux_session("shuttle-tests/haiku")
    send(poller, {:worker_exited, "tests/haiku", :normal_exit, false})
    Process.sleep(50)

    snap = Poller.snapshot(poller)
    assert snap.claimed_count == 0
    assert length(snap.retrying) == 0
  end

  test "poller adopts orphan tmux sessions on startup" do
    fiber = make_fiber("tests/orphan")
    MockRunner.set_fiber("tests/orphan", fiber)
    MockRunner.add_tmux_session("shuttle-tests/orphan")

    {:ok, poller} = Poller.start_link(
      name: :test_poller_9,
      runner: MockRunner,
      poll_interval_ms: 60_000,
      felt_host: "/tmp"
    )

    Process.sleep(100)

    snap = Poller.snapshot(poller)
    assert length(snap.eligible) == 1
    assert hd(snap.eligible).fiber_id == "tests/orphan"
  end
end
