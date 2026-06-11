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
      },
      "tests/uid-fiber" => %{
        status: "active",
        tags: ["constitution"],
        uid: "01KTHDNZS287ZSSG8X8V59XKWB",
        shuttle: %{"enabled" => true, "kind" => "oneshot", "agent" => "claude-sonnet"}
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

          if tmux_session_exists?(tmux_sessions(), session) do
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

    defp tmux_session_exists?(sessions, "=" <> session), do: MapSet.member?(sessions, session)

    defp tmux_session_exists?(sessions, session) do
      Enum.any?(sessions, &(&1 == session or String.starts_with?(&1, session <> "/")))
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
            |> maybe_put("uid", Map.get(fiber, :uid))

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

  test "render_prompt opens with orientation, names the fiber, and carries exit contract" do
    # No felt index for tests/haiku → all three context blocks render empty;
    # this test exercises the orientation header.
    prompt = Dispatcher.render_prompt("tests/haiku")

    # Orientation paragraph: names what Shuttle is, what the worker is for,
    # how the practice gets loaded.
    assert prompt =~ "The orchestration system Shuttle dispatched you"
    assert prompt =~ ~s(constitution describes what "done" looks like)
    assert prompt =~ "`shuttle` and `felt` skills carry the practice"

    # Fiber identity on its own line for grep-ability.
    assert prompt =~ "Fiber: tests/haiku"

    # The full practice still lives in the shuttle skill, but the exit
    # contract must be prompt-local so resumed workers do not treat Shuttle
    # work like ordinary chat completion.
    assert prompt =~ "Exit Contract"
    assert prompt =~ "kill $PPID"
    assert prompt =~ "Do not substitute a normal chat final response"
    refute prompt =~ "felt history append"
    refute prompt =~ "Exit before context is half-full"
  end

  test "render_prompt names the felt store so the safe-fail global id stays resolvable" do
    # When prompt_fiber_id's local translation misses, the worker holds a
    # global id that doesn't resolve from cwd. The store line makes the
    # fallback mechanical: `felt -C <felt-store> show <id>`.
    prompt = Dispatcher.render_prompt("tests/haiku", felt_store: "/tmp/some-loom")
    assert prompt =~ "Felt store: /tmp/some-loom"

    # Default store renders too — the line is unconditional.
    default_prompt = Dispatcher.render_prompt("tests/haiku")
    assert default_prompt =~ "Felt store: "
  end

  test "render_prompt omits the From User block when there's no review-comment" do
    # tests/haiku has no felt index; the user-message block suppresses to
    # an empty string, leaving just the header.
    prompt = Dispatcher.render_prompt("tests/haiku")
    refute prompt =~ "From User"
  end

  test "render_prompt does not inline outcome or last-session (worker reads via felt)" do
    # The fiber's outcome and last editorial event are reachable via
    # `felt show <id>` and `felt history <id>` respectively. The prompt
    # deliberately doesn't duplicate them — the shuttle skill prescribes
    # the read order, and inlining risks drift between the prompt's
    # snapshot and felt's view.
    prompt = Dispatcher.render_prompt("tests/haiku")
    refute prompt =~ "Outcome"
    refute prompt =~ "Last session"
  end

  test "prompt_fiber_id uses the worker cwd's project-local felt view" do
    loom =
      Path.join(System.tmp_dir!(), "shuttle-prompt-loom-#{System.unique_integer([:positive])}")

    work_dir =
      Path.join(System.tmp_dir!(), "shuttle-prompt-work-#{System.unique_integer([:positive])}")

    canonical_path =
      Path.join([
        loom,
        ".felt",
        "ai-futures",
        "shuttle",
        "constitution-shuttle-ctl-ux-fixes",
        "constitution-shuttle-ctl-ux-fixes.md"
      ])

    File.mkdir_p!(Path.dirname(canonical_path))
    File.write!(canonical_path, "---\nname: test\n---\n")
    File.mkdir_p!(work_dir)
    File.ln_s!(Path.join([loom, ".felt", "ai-futures", "shuttle"]), Path.join(work_dir, ".felt"))

    on_exit(fn ->
      File.rm_rf!(loom)
      File.rm_rf!(work_dir)
    end)

    assert Dispatcher.prompt_fiber_id(
             "ai-futures/shuttle/constitution-shuttle-ctl-ux-fixes",
             work_dir,
             loom
           ) == "constitution-shuttle-ctl-ux-fixes"
  end

  test "prompt_fiber_id preserves nested IDs under the project felt root" do
    loom =
      Path.join(System.tmp_dir!(), "shuttle-prompt-loom-#{System.unique_integer([:positive])}")

    work_dir =
      Path.join(System.tmp_dir!(), "shuttle-prompt-work-#{System.unique_integer([:positive])}")

    canonical_path =
      Path.join([
        loom,
        ".felt",
        "ai-futures",
        "portolan",
        "portolan",
        "constitution-shuttle-portolan-version-sync",
        "constitution-shuttle-portolan-version-sync.md"
      ])

    File.mkdir_p!(Path.dirname(canonical_path))
    File.write!(canonical_path, "---\nname: test\n---\n")
    File.mkdir_p!(work_dir)
    File.ln_s!(Path.join([loom, ".felt", "ai-futures", "portolan"]), Path.join(work_dir, ".felt"))

    on_exit(fn ->
      File.rm_rf!(loom)
      File.rm_rf!(work_dir)
    end)

    assert Dispatcher.prompt_fiber_id(
             "ai-futures/portolan/portolan/constitution-shuttle-portolan-version-sync",
             work_dir,
             loom
           ) == "portolan/constitution-shuttle-portolan-version-sync"
  end

  test "render_prompt can display a project-local fiber while querying canonical history" do
    prompt =
      Dispatcher.render_prompt("ai-futures/shuttle/constitution-shuttle-ctl-ux-fixes",
        prompt_fiber_id: "constitution-shuttle-ctl-ux-fixes"
      )

    assert prompt =~ "Fiber: constitution-shuttle-ctl-ux-fixes"
    refute prompt =~ "Fiber: ai-futures/shuttle/constitution-shuttle-ctl-ux-fixes"
  end

  test "session_name/2 keys the canonical name by uid (rename-safe, collision-free)" do
    uid = "01KTHDNZS287ZSSG8X8V59XKWB"
    assert Dispatcher.session_name("tests/haiku", uid) == "haiku-#{uid}-shuttle"
    assert Dispatcher.session_name("a/b/c", uid) == "c-#{uid}-shuttle"
  end

  test "session_name/2 falls back to the legacy leaf-only name when uid is absent" do
    assert Dispatcher.session_name("tests/haiku", nil) == "haiku-shuttle"
    assert Dispatcher.session_name("tests/haiku", "") == "haiku-shuttle"
  end

  test "session_name/1 is the legacy leaf-only form (retained for dual-recognition)" do
    assert Dispatcher.session_name("tests/haiku") == "haiku-shuttle"
    assert Dispatcher.session_name("a/b/c") == "c-shuttle"
  end

  test "session_names/2 returns both forms for dual-recognition" do
    uid = "01KTHDNZS287ZSSG8X8V59XKWB"

    assert Dispatcher.session_names("tests/haiku", uid) == [
             "haiku-#{uid}-shuttle",
             "haiku-shuttle"
           ]

    # No uid → only the legacy form is recognizable.
    assert Dispatcher.session_names("tests/haiku", nil) == ["haiku-shuttle"]

    # Both forms are Shuttle sessions.
    assert Enum.all?(Dispatcher.session_names("tests/haiku", uid), &Dispatcher.shuttle_session?/1)
  end

  test "dispatch creates tmux session for eligible fiber" do
    result = Dispatcher.dispatch("tests/haiku", runner: MockRunner)
    assert {:ok, "haiku-shuttle"} = result

    commands = MockRunner.commands()

    assert Enum.any?(commands, fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)
  end

  test "dispatch launches the worker under the uid-keyed session name" do
    uid = "01KTHDNZS287ZSSG8X8V59XKWB"
    expected = "uid-fiber-#{uid}-shuttle"
    assert {:ok, ^expected} = Dispatcher.dispatch("tests/uid-fiber", runner: MockRunner)

    # The new-session tmux command targets the uid-keyed name.
    assert Enum.any?(MockRunner.commands(), fn
             {"tmux", args} -> hd(args) == "new-session" and expected in args
             _ -> false
           end)
  end

  test "dispatch refuses when a live worker exists under the legacy name (dual-recognition)" do
    # A worker launched before the uid-keyed cutover carries the legacy
    # leaf-only name; check_not_running must still see it and refuse a
    # duplicate dispatch for the uid-carrying fiber.
    MockRunner.add_tmux_session("uid-fiber-shuttle")
    assert {:error, :already_running} = Dispatcher.dispatch("tests/uid-fiber", runner: MockRunner)
  end

  test "dispatch refuses closed fiber" do
    result = Dispatcher.dispatch("tests/closed", runner: MockRunner)
    assert {:error, :closed} = result
  end

  test "dispatch with force: true on a closed fiber shells out to shuttle-ctl reopen" do
    # The kanban Resume button on an awaitingReview / closed card flows here
    # with force=true. Without the reopen step, the worker spawns but the
    # YAML stays closed and Portolan's classifyFiber keeps the card pinned
    # in its prior column — see KanbanModal.runRequeue's comment about why
    # this side-effect is daemon-owned. The contract: force-dispatch on a
    # not-already-clean fiber issues `shuttle-ctl reopen <fiber>` before
    # tmux new-session fires.
    result = Dispatcher.dispatch("tests/closed", runner: MockRunner, force: true)
    assert {:ok, _session} = result

    commands = MockRunner.commands()

    reopen_call =
      Enum.find(commands, fn
        {"shuttle-ctl", args} -> "reopen" in args and "tests/closed" in args
        _ -> false
      end)

    assert reopen_call != nil, "expected shuttle-ctl reopen call; got #{inspect(commands)}"

    # And it must precede tmux new-session — reopen-then-spawn, not the other way.
    reopen_index =
      Enum.find_index(commands, fn
        {"shuttle-ctl", args} -> "reopen" in args
        _ -> false
      end)

    tmux_new_index =
      Enum.find_index(commands, fn
        {"tmux", args} -> hd(args) == "new-session"
        _ -> false
      end)

    assert reopen_index < tmux_new_index,
           "reopen must precede tmux new-session; commands: #{inspect(commands)}"
  end

  test "dispatch with force: true on an already-clean fiber skips the reopen shell-out" do
    # No-op short-circuit: re-dispatching a healthy in-flight oneshot
    # shouldn't rewrite frontmatter on every manual click.
    result =
      Dispatcher.dispatch("tests/shuttle-agent-block",
        runner: MockRunner,
        force: true,
        store_session_id: false
      )

    assert {:ok, _session} = result

    refute Enum.any?(MockRunner.commands(), fn
             {"shuttle-ctl", args} -> "reopen" in args
             _ -> false
           end),
           "expected no shuttle-ctl reopen on already-clean fiber; got #{inspect(MockRunner.commands())}"
  end

  test "dispatch refuses already-running fiber" do
    # Pre-seed the tmux session
    MockRunner.add_tmux_session(Dispatcher.session_name("tests/haiku"))

    result = Dispatcher.dispatch("tests/haiku", runner: MockRunner)
    assert {:error, :already_running} = result
  end

  test "dispatch does not treat child fiber session as already-running parent" do
    MockRunner.add_tmux_session(Dispatcher.session_name("tests/haiku/child"))

    result = Dispatcher.dispatch("tests/haiku", runner: MockRunner)
    assert {:ok, "haiku-shuttle"} = result

    assert Enum.any?(MockRunner.commands(), fn
             {"tmux", ["has-session", "-t", "=haiku-shuttle"]} -> true
             _ -> false
           end)
  end

  test "dispatch resolves pi agent from bare tag" do
    result = Dispatcher.dispatch("tests/pi-tagged", runner: MockRunner, store_session_id: false)
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
    script = read_run_script_for(Dispatcher.session_name("tests/shuttle-agent-block"))
    assert script =~ "agent=claude-opus"
    refute script =~ "agent=claude-sonnet"
  end

  test "dispatch: shuttle.agent overrides legacy bare tag" do
    assert {:ok, _session} =
             Dispatcher.dispatch("tests/shuttle-agent-overrides-tag", runner: MockRunner)

    script = read_run_script_for(Dispatcher.session_name("tests/shuttle-agent-overrides-tag"))
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

  test "build_command for codex spark selects the spark model" do
    agent = Enum.find(Agents.list(), &(&1.id == "codex-spark"))
    refute is_nil(agent), "expected codex-spark agent in defaults"
    cmd = Agents.build_command(agent, "hello world")
    assert cmd =~ "codex"
    assert cmd =~ "--model 'gpt-5.3-codex-spark'"
    assert cmd =~ "'hello world'"
    refute cmd =~ "<<<"
  end

  test "build_command for pi includes provider and model" do
    agent = Enum.find(Agents.list(), &(&1.id == "pi-kimi"))
    refute is_nil(agent), "expected pi-kimi agent in defaults"
    cmd = Agents.build_command(agent, "hello world")
    assert cmd =~ "pi"
    assert cmd =~ "--provider 'openrouter'"
    assert cmd =~ "--model 'moonshotai/kimi-k2.6'"
  end

  # ── Axis rendering (effort × chrome) per harness ──

  test "claude effort renders --effort and chrome renders --chrome" do
    {:ok, agent} = Agents.resolve_with_axes("claude-opus", "xhigh", true)
    cmd = Agents.build_command(agent, "hi")
    assert cmd =~ "--effort 'xhigh'"
    assert cmd =~ "--chrome"
  end

  test "claude with no axes renders neither --effort nor --chrome" do
    {:ok, agent} = Agents.resolve_with_axes("claude-opus", nil, false)
    cmd = Agents.build_command(agent, "hi")
    refute cmd =~ "--effort"
    refute cmd =~ "--chrome"
  end

  test "pi renders effort as :level suffix on the model" do
    {:ok, agent} = Agents.resolve_with_axes("pi-gpt-5.4", "high", false)
    cmd = Agents.build_command(agent, "hi")
    assert cmd =~ "--model 'gpt-5.4:high'"
    refute cmd =~ "--effort"
  end

  test "pi default effort preserves the legacy suffix (pi-sonnet :high)" do
    {:ok, agent} = Agents.resolve_with_axes("pi-sonnet", nil, false)
    cmd = Agents.build_command(agent, "hi")
    assert cmd =~ "--model 'claude-sonnet-4.6:high'"
  end

  test "codex renders effort via -c model_reasoning_effort" do
    {:ok, agent} = Agents.resolve_with_axes("codex", "high", false)
    cmd = Agents.build_command(agent, "hi")
    assert cmd =~ ~s(-c model_reasoning_effort='high')
  end

  test "claude-opus-chrome alias expands to claude-opus + --chrome" do
    {:ok, agent} = Agents.resolve_with_axes("claude-opus-chrome", nil, false)
    assert agent.id == "claude-opus"
    cmd = Agents.build_command(agent, "hi")
    assert cmd =~ "--model 'opus'"
    assert cmd =~ "--chrome"
  end

  test "effort out of range is rejected (Copilot Sonnet capped at high)" do
    assert {:error, msg} = Agents.resolve_with_axes("pi-sonnet", "xhigh", false)
    assert msg =~ "not allowed"
  end

  test "chrome on a non-claude harness is rejected" do
    assert {:error, msg} = Agents.resolve_with_axes("codex", nil, true)
    assert msg =~ "chrome not supported"
  end

  test "effort on an agent without an effort axis is rejected" do
    assert {:error, msg} = Agents.resolve_with_axes("pi-kimi", "high", false)
    assert msg =~ "does not support an effort"
  end

  test "resolve_with_axes accepts a registry alias (codex → codex base)" do
    {:ok, agent} = Agents.resolve_with_axes("codex", nil, false)
    assert agent.cli == "codex"
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

  test "render_standing_run_prompt frames the run as a recurring occurrence" do
    prompt = Dispatcher.render_standing_run_prompt("tests/haiku", "run-2026-05-06")

    # Standing-role-specific framing
    assert prompt =~ "scheduled run of this standing role"
    assert prompt =~ "one due occurrence, not a new fiber"
    assert prompt =~ "awaiting-review handoff at run completion"

    # Identity lines
    assert prompt =~ "Fiber: tests/haiku"
    assert prompt =~ "Run:"
    assert prompt =~ "run-2026-05-06"

    # The run-specific frontmatter handoff remains in the skill; the generic
    # autonomous-worker exit contract is prompt-local.
    assert prompt =~ "Exit Contract"
    assert prompt =~ "kill $PPID"
    refute prompt =~ "review.state: awaiting"
    refute prompt =~ "felt history append"
  end

  test "render_standing_run_prompt distinguishes ad-hoc runs from scheduled occurrences" do
    prompt =
      Dispatcher.render_standing_run_prompt("tests/haiku", "adhoc-1770000000000", ad_hoc: true)

    assert prompt =~ "ad-hoc run of this standing role"
    assert prompt =~ "does not consume or advance the scheduled occurrence"
    # The slice-5 schema freeze removed review.state and next_due_at; the
    # prompt must not instruct the worker to write either. The daemon owns
    # the awaiting transition (standing-roles.md, "Worker exit handoff").
    refute prompt =~ "review.state"
    refute prompt =~ "next_due_at"
    assert prompt =~ "daemon owns the awaiting transition"
    assert prompt =~ "Run:   adhoc-1770000000000"
  end

  test "resolve_resume_intent forces :fresh for ad-hoc dispatch even with stored session" do
    # An ad-hoc run is "do this responsibility right now" work. The prior
    # session's transcript may have wrapped on a "Run accepted. Exiting"
    # turn — resuming there leads to an idle worker that says "nothing new
    # on the fiber" instead of running the responsibility afresh. The
    # ad-hoc branch must short-circuit to :fresh regardless of any stored
    # session UUID or review-comment resume_mode the fiber's history carries.
    fiber_with_session = %{
      "shuttle" => %{
        "session" => %{"id" => "11111111-2222-3333-4444-555555555555"}
      }
    }

    assert Dispatcher.resolve_resume_intent(
             {:standing_run, "adhoc-1770000000000", :ad_hoc},
             "tests/haiku",
             fiber_with_session,
             nil
           ) == :fresh
  end

  test "resolve_resume_intent defers to check_resume_intent for non-ad-hoc dispatches" do
    # The delegation boundary: anything other than {:standing_run, _, :ad_hoc}
    # takes the existing review-comment-driven path. With no felt history in
    # the test env, check_resume_intent returns :fresh as the safe default —
    # but it's the path being taken that matters, not the value.
    fiber = %{}

    # Scheduled standing run: defer
    assert Dispatcher.resolve_resume_intent(
             {:standing_run, "20260508T070000+0000"},
             "tests/haiku",
             fiber,
             nil
           ) == :fresh

    # Plain constitution dispatch: defer
    assert Dispatcher.resolve_resume_intent(:constitution, "tests/haiku", fiber, nil) == :fresh
  end

  test "render_resume_prompt names the fiber and repeats the exit contract" do
    # No felt history available in test env (no .felt index) — context
    # blocks suppress to empty; the framing block still renders.
    prompt = Dispatcher.render_resume_prompt("tests/haiku")

    assert prompt =~ "Shuttle resumed your previous session"
    assert prompt =~ "Fiber: tests/haiku"
    assert prompt =~ "already loaded in your transcript"
    assert prompt =~ "Exit Contract"
    assert prompt =~ "kill $PPID"
    assert prompt =~ "Do not substitute a normal chat final response"

    # Resume prompt deliberately omits the fresh-dispatch orientation —
    # skills, conventions, and the constitution are already in scope.
    refute prompt =~ "The orchestration system Shuttle dispatched you"
  end

  # ── Resume-warning dismiss in run script ──

  test "build_run_script with dismiss_resume_warning embeds backgrounded send-keys" do
    script =
      Dispatcher.build_run_script("tests/haiku", "claude --resume 'abc'", "claude-sonnet",
        dismiss_resume_warning: true,
        session: "haiku-shuttle"
      )

    assert script =~ "sleep 2"
    assert script =~ "tmux send-keys -t 'haiku-shuttle' Enter"
    # The dismiss block runs in the background (suffixed with `&`) so it
    # doesn't block the harness command itself.
    assert script =~ ") &"
  end

  test "build_run_script without dismiss_resume_warning emits no send-keys" do
    script =
      Dispatcher.build_run_script("tests/haiku", "claude --resume 'abc'", "claude-sonnet",
        dismiss_resume_warning: false,
        session: "haiku-shuttle"
      )

    refute script =~ "send-keys"
  end

  test "build_run_script with no opts (fresh dispatch path) emits no send-keys" do
    # Default opts = [] → dismiss_resume_warning defaults to false. This is
    # the path fresh dispatch takes, so fresh workers never get the dismiss.
    script = Dispatcher.build_run_script("tests/haiku", "claude <<< 'hi'", "claude-sonnet")
    refute script =~ "send-keys"
  end

  test "build_run_script can show a project-local fiber handle in the worker banner" do
    script =
      Dispatcher.build_run_script(
        "ai-futures/shuttle/constitution-shuttle-ctl-ux-fixes",
        "codex exec",
        "codex",
        display_fiber_id: "constitution-shuttle-ctl-ux-fixes"
      )

    assert script =~ "Shuttle worker — constitution-shuttle-ctl-ux-fixes"
    refute script =~ "Shuttle worker — ai-futures/shuttle/constitution-shuttle-ctl-ux-fixes"
  end

  # ── Wait-for-client guard before harness start ──

  test "build_run_script with session waits for a non-control client before the harness" do
    # Without this wait, the harness initializes inside the detached
    # session's 80x24 default-size and bakes its dispatch banner into
    # scrollback at 80 cols — the symptom that drove this gate in.
    script =
      Dispatcher.build_run_script("tests/haiku", "claude --resume 'abc'", "claude-sonnet",
        session: "haiku-shuttle"
      )

    assert script =~ "tmux list-clients -t 'haiku-shuttle'"
    # Filter out tmux's control-mode clients (Portolan's wterm preview
    # uses `tmux -C attach -r` and would otherwise satisfy the wait
    # without a real human terminal attached).
    assert script =~ "client_control_mode"
    assert script =~ "grep -qx '0'"
    # Bounded wait: autonomous dispatches still proceed if no human
    # attaches in time.
    assert script =~ "WAIT_DEADLINE"
    # The wait precedes the start banner so the banner renders at the
    # attached client's terminal size, not at 80x24.
    [wait_idx, banner_idx] =
      Enum.map(["WAIT_DEADLINE", "Shuttle worker —"], fn needle ->
        :binary.match(script, needle) |> elem(0)
      end)

    assert wait_idx < banner_idx
  end

  test "build_run_script with no session skips the wait" do
    # spawn_tmux always passes a session, but the function defaults
    # session to "" — guard against accidental no-session callers
    # spinning forever on a session that doesn't exist.
    script = Dispatcher.build_run_script("tests/haiku", "claude <<< 'hi'", "claude-sonnet")
    refute script =~ "tmux list-clients"
    refute script =~ "WAIT_DEADLINE"
  end

  # ── Capture (spawn-without-constitution) ──

  test "render_capture_prompt carries the yap, store, claim call, and contract" do
    prompt =
      Dispatcher.render_capture_prompt("make the board sing\nwith two lines",
        session: "capture-ab12cd34",
        felt_store: "/Users/x/loom",
        port: 4123,
        session_uuid: "uuid-cap-1",
        agent_id: "claude-opus",
        project_dir: "/Users/x/projects/portolan",
        host: "test-host"
      )

    # The yap, verbatim, in the From User block.
    assert prompt =~ "make the board sing\n  with two lines"
    assert prompt =~ "From User"
    # Crystallize instructions + anchors.
    assert prompt =~ "Felt store: /Users/x/loom"
    assert prompt =~ "Project dir: /Users/x/projects/portolan"
    assert prompt =~ "kind: oneshot"
    assert prompt =~ "agent: claude-opus"
    assert prompt =~ "host: test-host"
    # The claim callback, with this session's identity baked in.
    assert prompt =~ "http://localhost:4123/api/v1/claim"
    assert prompt =~ ~s("tmux_session": "capture-ab12cd34")
    assert prompt =~ ~s("session_uuid": "uuid-cap-1")
    # Worker exit contract present (capture sessions become ordinary workers).
    assert prompt =~ "kill $PPID"
  end

  test "capture spawns a non-shuttle-suffixed session with the prompt in the run script" do
    {:ok, %{session: session, session_uuid: uuid, agent_id: "claude-fable"}} =
      Dispatcher.capture("an idea", runner: MockRunner, work_dir: "/tmp", felt_store: "/tmp")

    assert session =~ ~r/^capture-[0-9a-f]{8}$/
    refute String.ends_with?(session, "-shuttle")
    assert is_binary(uuid)

    {_, args} =
      Enum.find(MockRunner.commands(), fn {cmd, args} ->
        cmd == "tmux" and hd(args) == "new-session"
      end)

    assert Enum.at(args, 3) == session
    assert Enum.at(args, 5) == "/tmp"

    # The run script (written to disk, handed to tmux) carries the yap and
    # the claim call with this session's identity baked in.
    script = File.read!(List.last(args))
    assert script =~ "an idea"
    assert script =~ "/api/v1/claim"
    assert script =~ session
    assert script =~ uuid
  end

  test "capture renders requested axes into the command and the install-block step" do
    {:ok, %{session: _}} =
      Dispatcher.capture("an idea",
        runner: MockRunner,
        work_dir: "/tmp",
        felt_store: "/tmp",
        agent: "claude-opus",
        effort: "xhigh",
        chrome: true
      )

    {_, args} =
      Enum.find(MockRunner.commands(), fn {cmd, args} ->
        cmd == "tmux" and hd(args) == "new-session"
      end)

    script = File.read!(List.last(args))
    # Axes rendered on the CLI invocation.
    assert script =~ "--effort 'xhigh'"
    assert script =~ "--chrome"
    # Axes recorded in the crystallize instructions so the fiber reproduces them.
    assert script =~ "`effort: xhigh`"
    assert script =~ "`chrome: true`"
  end

  test "capture rejects axes outside the agent's constraints" do
    assert {:error, reason} =
             Dispatcher.capture("an idea",
               runner: MockRunner,
               work_dir: "/tmp",
               felt_store: "/tmp",
               agent: "codex",
               chrome: true
             )

    assert reason =~ "chrome not supported"

    assert {:error, reason2} =
             Dispatcher.capture("an idea",
               runner: MockRunner,
               work_dir: "/tmp",
               felt_store: "/tmp",
               agent: "claude-opus",
               effort: "bogus"
             )

    assert reason2 =~ "effort bogus not allowed"
  end
end
