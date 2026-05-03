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

        command == "felt" and String.contains?(full_args, "tests/shuttle-agent-block") ->
          {shuttle_agent_block_fiber_json(), 0}

        command == "felt" and String.contains?(full_args, "tests/shuttle-agent-overrides-tag") ->
          {shuttle_agent_overrides_tag_fiber_json(), 0}

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

    defp shuttle_agent_block_fiber_json do
      Jason.encode!(%{
        "id" => "tests/shuttle-agent-block",
        "name" => "Shuttle agent block",
        "status" => "active",
        "tags" => ["constitution"],
        "shuttle" => %{"enabled" => true, "kind" => "oneshot", "agent" => "claude-opus"},
        "created_at" => "2026-04-28T00:00:00Z"
      })
    end

    defp shuttle_agent_overrides_tag_fiber_json do
      # Even with a legacy bare `pi` tag (would resolve to pi-deepseek-flash),
      # shuttle.agent should win — the post-migration source of truth.
      Jason.encode!(%{
        "id" => "tests/shuttle-agent-overrides-tag",
        "name" => "Shuttle agent overrides tag",
        "status" => "active",
        "tags" => ["constitution", "pi"],
        "shuttle" => %{"enabled" => true, "kind" => "oneshot", "agent" => "claude-opus"},
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
    MockRunner.add_tmux_session(Dispatcher.session_name("tests/haiku"))

    result = Dispatcher.dispatch("tests/haiku", runner: MockRunner)
    assert {:error, :already_running} = result
  end

  test "dispatch resolves pi agent from bare tag" do
    result = Dispatcher.dispatch("tests/pi-tagged", runner: MockRunner)
    assert {:ok, session} = result
    assert session == Dispatcher.session_name("tests/pi-tagged")

    # Verify the tmux new-session command was issued
    commands = MockRunner.commands()

    {_, args} =
      Enum.find(commands, fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)

    assert hd(args) == "new-session"
  end

  test "dispatch resolves agent from shuttle.agent block when present" do
    assert {:ok, _session} = Dispatcher.dispatch("tests/shuttle-agent-block", runner: MockRunner)
    script = read_run_script_for("shuttle-tests/shuttle-agent-block")
    assert script =~ "agent=claude-opus"
    refute script =~ "agent=claude-sonnet"
  end

  test "dispatch: shuttle.agent overrides legacy bare tag" do
    assert {:ok, _session} =
             Dispatcher.dispatch("tests/shuttle-agent-overrides-tag", runner: MockRunner)

    script = read_run_script_for("shuttle-tests/shuttle-agent-overrides-tag")
    assert script =~ "agent=claude-opus"
    refute script =~ "agent=pi-deepseek-flash"
  end

  # The dispatched tmux command takes a run-script tempfile as the last arg
  # (after `bash -l`). Read the script back to verify the agent embedded in it.
  defp read_run_script_for(session) do
    {_, args} =
      Enum.find(MockRunner.commands(), fn {cmd, args} ->
        cmd == "tmux" and hd(args) == "new-session" and Enum.at(args, 3) == session
      end)

    script_path = List.last(args)
    File.read!(script_path)
  end

  test "agent resolution: default is claude-sonnet" do
    assert {:ok, agent} = Agents.resolve(["constitution"])
    assert agent.id == "claude-sonnet"
    assert agent.model == "sonnet"
  end

  test "agent resolution: compound tag" do
    assert {:ok, agent} = Agents.resolve(["constitution", "agent:pi-kimi"])
    assert agent.id == "pi-kimi"
    assert agent.provider == "openrouter"
  end

  test "agent resolution: bare codex tag" do
    assert {:ok, agent} = Agents.resolve(["constitution", "codex"])
    assert agent.id == "codex"
  end

  test "agent resolution: bare pi tag resolves to pi-deepseek-flash" do
    assert {:ok, agent} = Agents.resolve(["constitution", "pi"])
    assert agent.id == "pi-deepseek-flash"
    assert agent.model == "deepseek/deepseek-v4-flash"
  end

  test "agent resolution reads application config" do
    previous = Application.get_env(:shuttle, :agents)

    try do
      Application.put_env(:shuttle, :agents, [
        [
          id: "local-codex",
          cli: "codex",
          wrapper: "codex-nightly",
          aliases: ["codex"],
          default: true
        ]
      ])

      assert [%{id: "local-codex", wrapper: "codex-nightly"}] = Agents.list()
      assert {:ok, agent} = Agents.resolve(["constitution", "codex"])
      assert agent.id == "local-codex"
      assert agent.wrapper == "codex-nightly"
    after
      if previous do
        Application.put_env(:shuttle, :agents, previous)
      else
        Application.delete_env(:shuttle, :agents)
      end
    end
  end

  test "agent resolution falls back to first configured agent when no default is set" do
    previous = Application.get_env(:shuttle, :agents)

    try do
      Application.put_env(:shuttle, :agents, [
        [id: "first", cli: "first", wrapper: "first"],
        [id: "second", cli: "second", wrapper: "second"]
      ])

      assert {:ok, agent} = Agents.resolve(["constitution"])
      assert agent.id == "first"
    after
      if previous do
        Application.put_env(:shuttle, :agents, previous)
      else
        Application.delete_env(:shuttle, :agents)
      end
    end
  end

  test "build_command for claude uses here-string" do
    agent = Enum.find(Agents.list(), &(&1.id == "claude-sonnet"))
    refute is_nil(agent), "expected claude-sonnet agent in defaults"
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
    agent = Enum.find(Agents.list(), &(&1.id == "pi-kimi"))
    refute is_nil(agent), "expected pi-kimi agent in defaults"
    cmd = Agents.build_command(agent, "hello world")
    assert cmd =~ "pi"
    assert cmd =~ "--provider 'openrouter'"
    assert cmd =~ "--model 'moonshotai/kimi-k2.6'"
  end
end
