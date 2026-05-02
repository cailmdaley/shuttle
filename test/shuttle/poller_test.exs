defmodule Shuttle.PollerTest do
  use ExUnit.Case

  alias Shuttle.Poller
  alias Shuttle.Dispatcher

  # ── Mock Runner ──

  defmodule MockRunner do
    @behaviour Shuttle.Runner

    use Agent

    def start_link(_ \\ []) do
      Agent.start_link(
        fn ->
          %{
            commands: [],
            tmux_sessions: MapSet.new(),
            fibers: %{},
            shuttle: %{},
            felt_ls: []
          }
        end,
        name: __MODULE__
      )
    end

    def reset do
      Agent.update(__MODULE__, fn _ ->
        %{
          commands: [],
          tmux_sessions: MapSet.new(),
          fibers: %{},
          shuttle: %{},
          felt_ls: []
        }
      end)
    end

    def set_fiber(id, fiber), do: Agent.update(__MODULE__, &put_in(&1.fibers[id], fiber))
    def set_shuttle(id, yaml), do: Agent.update(__MODULE__, &put_in(&1.shuttle[id], yaml))
    def set_felt_ls(fibers), do: Agent.update(__MODULE__, &%{&1 | felt_ls: fibers})

    def add_tmux_session(session),
      do: Agent.update(__MODULE__, &%{&1 | tmux_sessions: MapSet.put(&1.tmux_sessions, session)})

    def remove_tmux_session(session),
      do:
        Agent.update(__MODULE__, &%{&1 | tmux_sessions: MapSet.delete(&1.tmux_sessions, session)})

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

        command == "felt" and String.contains?(full_args, "show") and
            String.contains?(full_args, "--field shuttle") ->
          fiber_id = extract_fiber_id(args)
          shuttle = Agent.get(__MODULE__, & &1.shuttle)
          {Map.get(shuttle, fiber_id, ""), 0}

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
      # args like ["show", "tests/haiku", "--json"] or
      # ["show", "tests/haiku", "--field", "shuttle"]
      args
      |> Enum.reject(&(&1 in ["show", "--json", "--field", "shuttle"]))
      |> List.first("")
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
    Map.merge(
      %{
        "id" => id,
        "name" => id,
        "status" => "active",
        "tags" => ["constitution"],
        "created_at" => "2026-04-28T00:00:00Z"
      },
      attrs
    )
  end

  # ── Tests ──

  test "poller discovers and dispatches eligible fibers" do
    fiber = make_fiber("tests/haiku")
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/haiku", fiber)

    {:ok, poller} =
      Poller.start_link(
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

    {:ok, poller} =
      Poller.start_link(
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

    {:ok, poller} =
      Poller.start_link(
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

  test "poller does not dispatch a scheduled standing role before it is due" do
    fiber = make_fiber("tests/standing-sleeping", %{"tags" => ["constitution", "standing"]})
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/standing-sleeping", fiber)

    MockRunner.set_shuttle(
      "tests/standing-sleeping",
      """
      mode: standing
      schedule:
        kind: cron
        expr: "0 9 * * 1-5"
        timezone: Europe/Paris
      review:
        state: scheduled
      next_due_at: "2999-01-01T09:00:00+01:00"
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_sleeping,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_host: "/tmp"
      )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)

    assert [%{fiber_id: "tests/standing-sleeping", state: "scheduled"}] =
             Poller.snapshot(poller).standing_roles
  end

  test "poller dispatches a due standing role with run context and does not hot-loop after exit" do
    fiber = make_fiber("tests/standing-due", %{"tags" => ["constitution", "standing", "codex"]})
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/standing-due", fiber)

    MockRunner.set_shuttle(
      "tests/standing-due",
      """
      mode: standing
      schedule:
        kind: cron
        expr: "0 9 * * 1-5"
        timezone: Europe/Paris
      review:
        state: scheduled
      next_due_at: "2000-01-03T09:00:00+01:00"
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_due,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_host: "/tmp"
      )

    send(poller, :run_poll_cycle)
    Process.sleep(100)

    assert [%{fiber_id: "tests/standing-due", state: "running", run_id: run_id}] =
             Poller.snapshot(poller).eligible

    assert is_binary(run_id)

    MockRunner.remove_tmux_session(Dispatcher.session_name("tests/standing-due"))
    send(poller, {:worker_exited, "tests/standing-due", :normal_exit, false})
    Process.sleep(50)

    refute Enum.any?(Poller.snapshot(poller).retrying, &(&1.fiber_id == "tests/standing-due"))

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    new_session_count =
      MockRunner.commands()
      |> Enum.filter(fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)
      |> length()

    assert new_session_count == 1

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "felt" and Enum.take(args, 2) == ["standing", "review"]
           end)
  end

  test "poller rejects stale accepted standing metadata" do
    fiber = make_fiber("tests/standing-stale", %{"tags" => ["constitution", "standing"]})
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/standing-stale", fiber)

    MockRunner.set_shuttle(
      "tests/standing-stale",
      """
      mode: standing
      schedule:
        kind: cron
        expr: "0 9 * * 1-5"
        timezone: Europe/Paris
      review:
        state: accepted
        run_id: run-2
        accepted_run_id: run-1
      next_due_at: "2000-01-03T09:00:00+01:00"
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_stale,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_host: "/tmp"
      )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)

    assert [%{fiber_id: "tests/standing-stale", validation_errors: errors}] =
             Poller.snapshot(poller).standing_roles

    assert Enum.any?(errors, &String.contains?(&1, "accepted_run_id"))
  end

  test "snapshot exposes review and accepted standing states" do
    review = make_fiber("tests/standing-review", %{"tags" => ["constitution", "standing"]})
    accepted = make_fiber("tests/standing-accepted", %{"tags" => ["constitution", "standing"]})
    MockRunner.set_felt_ls([review, accepted])
    MockRunner.set_fiber("tests/standing-review", review)
    MockRunner.set_fiber("tests/standing-accepted", accepted)

    MockRunner.set_shuttle(
      "tests/standing-review",
      """
      mode: standing
      schedule:
        kind: cron
        expr: "0 9 * * 1-5"
        timezone: Europe/Paris
      review:
        state: awaiting
        run_id: run-1
        accepted_run_id: null
      next_due_at: null
      last_run_at: "2026-05-02T09:12:00+02:00"
      """
    )

    MockRunner.set_shuttle(
      "tests/standing-accepted",
      """
      mode: standing
      schedule:
        kind: cron
        expr: "0 9 * * 1-5"
        timezone: Europe/Paris
      review:
        state: accepted
        run_id: run-2
        accepted_run_id: run-2
      next_due_at: "2999-01-01T09:00:00+01:00"
      last_run_at: "2026-05-02T09:12:00+02:00"
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_snapshot_states,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_host: "/tmp"
      )

    roles = Poller.snapshot(poller).standing_roles
    assert Enum.find(roles, &(&1.fiber_id == "tests/standing-review")).state == "review"
    assert Enum.find(roles, &(&1.fiber_id == "tests/standing-accepted")).state == "accepted"
  end

  test "poller respects dependency satisfaction" do
    dep = make_fiber("tests/dep", %{"tempered" => false, "tags" => []})
    fiber = make_fiber("tests/dependent", %{"depends_on" => ["tests/dep"]})

    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/dependent", fiber)
    MockRunner.set_fiber("tests/dep", dep)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_4,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_host: "/tmp"
      )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    commands = MockRunner.commands()

    refute Enum.any?(commands, fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session" and
               Enum.member?(args, Dispatcher.session_name("tests/dependent"))
           end)
  end

  test "poller skips untracked fibers" do
    fiber = make_fiber("tests/untracked", %{"status" => "untracked"})
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/untracked", fiber)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_untracked,
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

  test "poller dispatches when dependencies are tempered" do
    dep = make_fiber("tests/dep", %{"tempered" => true})
    fiber = make_fiber("tests/dependent", %{"depends_on" => ["tests/dep"]})

    MockRunner.set_felt_ls([fiber, dep])
    MockRunner.set_fiber("tests/dependent", fiber)
    MockRunner.set_fiber("tests/dep", dep)

    {:ok, poller} =
      Poller.start_link(
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
    MockRunner.add_tmux_session(Dispatcher.session_name("tests/haiku"))

    {:ok, poller} =
      Poller.start_link(
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

    {:ok, poller} =
      Poller.start_link(
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
    MockRunner.remove_tmux_session(Dispatcher.session_name("tests/haiku"))
    send(poller, {:worker_exited, "tests/haiku", :normal_exit, false})
    Process.sleep(50)

    snap2 = Poller.snapshot(poller)
    assert length(snap2.eligible) == 0
    assert length(snap2.retrying) == 1
    assert hd(snap2.retrying).fiber_id == "tests/haiku"

    Process.sleep(1_100)

    new_session_count =
      MockRunner.commands()
      |> Enum.filter(fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)
      |> length()

    assert new_session_count == 2
  end

  test "poller releases claim when worker exits and fiber is closed" do
    fiber = make_fiber("tests/haiku")
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/haiku", fiber)

    {:ok, poller} =
      Poller.start_link(
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
    MockRunner.remove_tmux_session(Dispatcher.session_name("tests/haiku"))
    send(poller, {:worker_exited, "tests/haiku", :normal_exit, false})
    Process.sleep(50)

    snap = Poller.snapshot(poller)
    assert snap.claimed_count == 0
    assert length(snap.retrying) == 0
  end

  test "poller adopts orphan tmux sessions on startup" do
    fiber = make_fiber("tests/orphan")
    MockRunner.set_fiber("tests/orphan", fiber)
    MockRunner.add_tmux_session(Dispatcher.session_name("tests/orphan"))

    {:ok, poller} =
      Poller.start_link(
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

  test "poller adopts orphan sessions with literal hyphenated fiber ids" do
    fiber_id = "ai-futures/shuttle/constitution-shuttle-standalone"
    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "codex"]})
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.add_tmux_session(Dispatcher.session_name(fiber_id))

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_10,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_host: "/tmp"
      )

    Process.sleep(100)

    snap = Poller.snapshot(poller)
    assert [%{fiber_id: ^fiber_id, tmux_session: "shuttle-" <> ^fiber_id}] = snap.eligible
  end
end
