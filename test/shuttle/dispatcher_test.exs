defmodule Shuttle.DispatcherTest do
  use ExUnit.Case

  alias Shuttle.Dispatcher
  alias Shuttle.Agents

  # ── Mock Runner ──

  defmodule MockRunner do
    @behaviour Shuttle.Runner

    use Agent

    def start_link(_ \\ []) do
      Agent.start_link(fn -> %{commands: [], tmux_sessions: MapSet.new()} end, name: __MODULE__)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{commands: [], tmux_sessions: MapSet.new()} end)
    end

    def add_tmux_session(session) do
      Agent.update(__MODULE__, fn state ->
        %{state | tmux_sessions: MapSet.put(state.tmux_sessions, session)}
      end)
    end

    def commands do
      Agent.get(__MODULE__, & &1.commands)
    end

    def tmux_sessions do
      Agent.get(__MODULE__, & &1.tmux_sessions)
    end

    @impl true
    def cmd(command, args, _opts) do
      Agent.update(__MODULE__, fn state ->
        %{state | commands: state.commands ++ [{command, args}]}
      end)

      full_args = Enum.join(args, " ")

      cond do
        command == "felt" and String.contains?(full_args, "tests/haiku") ->
          {haiku_fiber_json(), 0}

        command == "felt" and String.contains?(full_args, "tests/closed") ->
          {closed_fiber_json(), 0}

        command == "felt" and String.contains?(full_args, "tests/pi-tagged") ->
          {pi_fiber_json(), 0}

        command == "felt" ->
          {"fiber not found", 1}

        command == "tmux" and hd(args) == "has-session" ->
          session = Enum.at(args, 2)

          if MapSet.member?(tmux_sessions(), session) do
            {"", 0}
          else
            {"can't find session", 1}
          end

        command == "tmux" and hd(args) == "new-session" ->
          session = Enum.at(args, 3)
          add_tmux_session(session)
          {"", 0}

        true ->
          {"", 0}
      end
    end

    defp haiku_fiber_json do
      Jason.encode!(%{
        "id" => "tests/haiku",
        "name" => "Haiku",
        "status" => "active",
        "tags" => ["constitution"],
        "created_at" => "2026-04-28T00:00:00Z"
      })
    end

    defp closed_fiber_json do
      Jason.encode!(%{
        "id" => "tests/closed",
        "name" => "Closed",
        "status" => "closed",
        "tags" => ["constitution"],
        "created_at" => "2026-04-28T00:00:00Z"
      })
    end

    defp pi_fiber_json do
      Jason.encode!(%{
        "id" => "tests/pi-tagged",
        "name" => "Pi Tagged",
        "status" => "active",
        "tags" => ["constitution", "pi"],
        "created_at" => "2026-04-28T00:00:00Z"
      })
    end
  end

  # ── Setup ──

  setup do
    start_supervised!(MockRunner)
    MockRunner.reset()
    :ok
  end

  # ── Tests ──

  test "render_prompt includes fiber ID and skill activation" do
    prompt = Dispatcher.render_prompt("tests/haiku")
    assert prompt =~ "Shuttle dispatch. Fiber ID: tests/haiku"
    assert prompt =~ "Activate the shuttle and felt skills"
    assert prompt =~ "kill $PPID"
    assert prompt =~ "felt history append tests/haiku"
  end

  test "session_name preserves slashes" do
    assert Dispatcher.session_name("tests/haiku") == "shuttle-tests/haiku"
    assert Dispatcher.session_name("a/b/c") == "shuttle-a/b/c"
  end

  test "dispatch creates tmux session for eligible fiber" do
    result = Dispatcher.dispatch("tests/haiku", runner: MockRunner)
    assert {:ok, "shuttle-tests/haiku"} = result

    commands = MockRunner.commands()
    assert Enum.any?(commands, fn {cmd, args} ->
      cmd == "tmux" and hd(args) == "new-session"
    end)
  end

  test "dispatch refuses closed fiber" do
    result = Dispatcher.dispatch("tests/closed", runner: MockRunner)
    assert {:error, :closed} = result
  end

  test "dispatch refuses already-running fiber" do
    # Pre-seed the tmux session
    MockRunner.add_tmux_session("shuttle-tests/haiku")

    result = Dispatcher.dispatch("tests/haiku", runner: MockRunner)
    assert {:error, :already_running} = result
  end

  test "dispatch resolves pi agent from bare tag" do
    result = Dispatcher.dispatch("tests/pi-tagged", runner: MockRunner)
    assert {:ok, "shuttle-tests/pi-tagged"} = result

    # Verify the tmux new-session command was issued
    commands = MockRunner.commands()
    {_, args} = Enum.find(commands, fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)
    assert hd(args) == "new-session"
  end

  test "agent resolution: default is claude" do
    assert {:ok, agent} = Agents.resolve(["constitution"])
    assert agent.id == "claude"
  end

  test "agent resolution: compound tag" do
    assert {:ok, agent} = Agents.resolve(["constitution", "agent:pi-google"])
    assert agent.id == "pi-google"
    assert agent.provider == "google"
  end

  test "agent resolution: bare codex tag" do
    assert {:ok, agent} = Agents.resolve(["constitution", "codex"])
    assert agent.id == "codex"
  end

  test "agent resolution: bare pi tag" do
    assert {:ok, agent} = Agents.resolve(["constitution", "pi"])
    assert agent.id == "pi-google"
  end

  test "build_command for claude uses here-string" do
    agent = Enum.find(Agents.list(), &(&1.id == "claude"))
    cmd = Agents.build_command(agent, "hello world")
    assert cmd =~ "claude"
    assert cmd =~ "<<<"
    assert cmd =~ "'hello world'"
  end

  test "build_command for codex uses positional arg" do
    agent = Enum.find(Agents.list(), &(&1.id == "codex"))
    cmd = Agents.build_command(agent, "hello world")
    assert cmd =~ "codex"
    refute cmd =~ "<<<"
    assert cmd =~ "'hello world'"
  end

  test "build_command for pi includes provider and model" do
    agent = Enum.find(Agents.list(), &(&1.id == "pi-google"))
    cmd = Agents.build_command(agent, "hello world")
    assert cmd =~ "pi"
    assert cmd =~ "--provider 'google'"
    assert cmd =~ "--model 'google/gemini-2.5-pro-preview'"
  end
end
