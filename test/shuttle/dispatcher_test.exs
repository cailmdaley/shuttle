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

    # Test fiber registry: id → %{status:, tags:, shuttle:}.
    #
    # `felt show --json` emits id/name/status/created_at/body/modified_at *only*
    # — it does NOT include `shuttle:` or `tags:` (verified against real felt).
    # `felt show --field shuttle` emits structured values as YAML; `--field
    # tags` emits sequences of scalars one-per-line. The cmd handler below
    # routes each `felt show` flavor through the right shape.
    @test_fibers %{
      "tests/haiku" => %{
        status: "active",
        tags: ["constitution"],
        shuttle: nil
      },
      "tests/closed" => %{
        status: "closed",
        tags: ["constitution"],
        shuttle: nil
      },
      "tests/pi-tagged" => %{
        status: "active",
        tags: ["constitution", "pi"],
        shuttle: nil
      },
      "tests/shuttle-agent-block" => %{
        status: "active",
        tags: ["constitution"],
        shuttle: %{"enabled" => true, "kind" => "oneshot", "agent" => "claude-opus"}
      },
      "tests/shuttle-agent-overrides-tag" => %{
        # Even with a legacy bare `pi` tag (would resolve to pi-deepseek-flash),
        # shuttle.agent should win — the post-migration source of truth.
        status: "active",
        tags: ["constitution", "pi"],
        shuttle: %{"enabled" => true, "kind" => "oneshot", "agent" => "claude-opus"}
      }
    }

    @impl true
    def cmd(command, args, _opts) do
      Agent.update(__MODULE__, fn state ->
        %{state | commands: state.commands ++ [{command, args}]}
      end)

      cond do
        command == "felt" ->
          handle_felt(args)

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

    defp handle_felt(args) do
      fiber_id = Enum.find(args, &Map.has_key?(@test_fibers, &1))

      cond do
        is_nil(fiber_id) ->
          {"fiber not found", 1}

        # `felt show <id> --json` (felt v1.0.4+) — tool-owned namespaces
        # like `shuttle:` round-trip as flat top-level JSON keys alongside
        # the parsed fields. The dispatcher reads `shuttle.agent` and
        # `tags` directly off the JSON map.
        "--json" in args ->
          fiber = @test_fibers[fiber_id]

          payload =
            %{
              "id" => fiber_id,
              "name" => fiber_id,
              "status" => fiber.status,
              "tags" => fiber.tags,
              "created_at" => "2026-04-28T00:00:00Z",
              "body" => "",
              "modified_at" => "2026-04-28T00:00:00Z"
            }
            |> maybe_put("shuttle", fiber.shuttle)

          {Jason.encode!(payload), 0}

        true ->
          {"", 0}
      end
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)
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

  # ── Resume command shape ──

  test "build_resume_command for claude with empty prompt: --resume only, no stdin pipe" do
    agent = Enum.find(Agents.list(), &(&1.id == "claude-sonnet"))
    cmd = Agents.build_resume_command(agent, "abc-123", "")
    assert cmd =~ "claude"
    assert cmd =~ "--resume 'abc-123'"
    refute cmd =~ "<<<"
  end

  test "build_resume_command for claude with prompt: pipes via here-string" do
    agent = Enum.find(Agents.list(), &(&1.id == "claude-sonnet"))
    cmd = Agents.build_resume_command(agent, "abc-123", "address the typo")
    assert cmd =~ "--resume 'abc-123'"
    assert cmd =~ "<<< 'address the typo'"
  end

  test "build_resume_command for claude with whitespace-only prompt: treated as empty" do
    agent = Enum.find(Agents.list(), &(&1.id == "claude-sonnet"))
    cmd = Agents.build_resume_command(agent, "abc-123", "   \n  ")
    refute cmd =~ "<<<"
  end

  test "build_resume_command for codex with prompt: positional arg" do
    agent = Enum.find(Agents.list(), &(&1.id == "codex"))
    cmd = Agents.build_resume_command(agent, "abc-123", "address the typo")
    assert cmd =~ "codex"
    assert cmd =~ "resume 'abc-123'"
    assert cmd =~ "'address the typo'"
    refute cmd =~ "<<<"
  end

  test "build_resume_command for codex with empty prompt: resume only" do
    agent = Enum.find(Agents.list(), &(&1.id == "codex"))
    cmd = Agents.build_resume_command(agent, "abc-123", "")
    assert cmd =~ "resume 'abc-123'"
    # No trailing prompt arg.
    assert String.trim_trailing(cmd) |> String.ends_with?("'abc-123'")
  end

  test "build_resume_command for pi: drops prompt (no inline arg supported)" do
    agent = Enum.find(Agents.list(), &(&1.id == "pi-kimi"))
    cmd = Agents.build_resume_command(agent, "abc-123", "ignored directive")
    assert cmd =~ "--session 'abc-123'"
    refute cmd =~ "ignored directive"
  end

  test "build_resume_command/2 default-arg form still works (zero-arg prompt)" do
    agent = Enum.find(Agents.list(), &(&1.id == "claude-sonnet"))
    cmd = Agents.build_resume_command(agent, "abc-123")
    assert cmd =~ "--resume 'abc-123'"
    refute cmd =~ "<<<"
  end

  # ── Resume prompt rendering ──

  test "render_resume_prompt includes resume framing and fiber id" do
    # No felt history available in test env (no .felt index) — query_history
    # falls back to []; the framing block still renders.
    prompt = Dispatcher.render_resume_prompt("tests/haiku")
    assert prompt =~ "Shuttle resume. Fiber ID: tests/haiku"
    assert prompt =~ "Resume previous"
    # Resume prompt deliberately omits the fresh-dispatch prologue.
    refute prompt =~ "Activate the shuttle and felt skills"
    refute prompt =~ "kill $PPID"
  end

  # ── Resume-warning dismiss in run script ──

  test "build_run_script with dismiss_resume_warning embeds backgrounded send-keys" do
    script =
      Dispatcher.build_run_script("tests/haiku", "claude --resume 'abc'", "claude-sonnet",
        dismiss_resume_warning: true,
        session: "shuttle-tests/haiku"
      )

    assert script =~ "sleep 2"
    assert script =~ "tmux send-keys -t 'shuttle-tests/haiku' Enter"
    # The dismiss block runs in the background (suffixed with `&`) so it
    # doesn't block the harness command itself.
    assert script =~ ") &"
  end

  test "build_run_script without dismiss_resume_warning emits no send-keys" do
    script =
      Dispatcher.build_run_script("tests/haiku", "claude --resume 'abc'", "claude-sonnet",
        dismiss_resume_warning: false,
        session: "shuttle-tests/haiku"
      )

    refute script =~ "send-keys"
  end

  test "build_run_script with no opts (fresh dispatch path) emits no send-keys" do
    # Default opts = [] → dismiss_resume_warning defaults to false. This is
    # the path fresh dispatch takes, so fresh workers never get the dismiss.
    script = Dispatcher.build_run_script("tests/haiku", "claude <<< 'hi'", "claude-sonnet")
    refute script =~ "send-keys"
  end
end
