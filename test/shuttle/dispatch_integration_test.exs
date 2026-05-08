defmodule Shuttle.DispatchIntegrationTest do
  use ExUnit.Case, async: false

  alias Shuttle.Dispatcher

  # ── Integration Runner ─────────────────────────────────────────────────────
  # Passes `felt` commands to the real felt CLI (with -C felt_store).
  # Intercepts `tmux` calls with an in-memory session set.
  # Named Agent so it can be injected as a module reference into Dispatcher.

  defmodule IntegrationRunner do
    @behaviour Shuttle.Runner

    use Agent

    def start_link(_ \\ []) do
      Agent.start_link(
        fn -> %{felt_store: "", commands: [], tmux_sessions: MapSet.new()} end,
        name: __MODULE__
      )
    end

    def reset(felt_store) do
      Agent.update(__MODULE__, fn _ ->
        %{felt_store: felt_store, commands: [], tmux_sessions: MapSet.new()}
      end)
    end

    def add_tmux_session(session),
      do: Agent.update(__MODULE__, &%{&1 | tmux_sessions: MapSet.put(&1.tmux_sessions, session)})

    def remove_tmux_session(session),
      do:
        Agent.update(__MODULE__, &%{&1 | tmux_sessions: MapSet.delete(&1.tmux_sessions, session)})

    def commands, do: Agent.get(__MODULE__, & &1.commands)
    def tmux_sessions, do: Agent.get(__MODULE__, & &1.tmux_sessions)

    @impl true
    def cmd("felt", args, opts) do
      felt_store = Agent.get(__MODULE__, & &1.felt_store)

      Agent.update(__MODULE__, fn s ->
        %{s | commands: s.commands ++ [{"felt", args}]}
      end)

      # Always use -C felt_store so the real felt finds our temp directory,
      # regardless of working directory. Drop :cd — redundant when -C is set.
      System.cmd("felt", ["-C", felt_store | args], Keyword.drop(opts, [:cd]))
    end

    def cmd("tmux", ["has-session", "-t", session], _opts) do
      Agent.update(__MODULE__, fn s ->
        %{s | commands: s.commands ++ [{"tmux", ["has-session", "-t", session]}]}
      end)

      sessions = Agent.get(__MODULE__, & &1.tmux_sessions)
      if MapSet.member?(sessions, session), do: {"", 0}, else: {"can't find session", 1}
    end

    def cmd("tmux", ["new-session" | _] = args, _opts) do
      # args = ["new-session", "-d", "-s", session, "-c", work_dir, "bash", "-l", script_path]
      session = Enum.at(args, 3)

      Agent.update(__MODULE__, fn s ->
        %{
          s
          | commands: s.commands ++ [{"tmux", args}],
            tmux_sessions: MapSet.put(s.tmux_sessions, session)
        }
      end)

      {"", 0}
    end

    def cmd(cmd, args, _opts) do
      Agent.update(__MODULE__, fn s -> %{s | commands: s.commands ++ [{cmd, args}]} end)
      {"", 0}
    end
  end

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup do
    start_supervised!(IntegrationRunner)
    host = mk_tmp_felt_store()
    IntegrationRunner.reset(host)
    on_exit(fn -> File.rm_rf!(host) end)
    {:ok, host: host}
  end

  # ── Tests ──────────────────────────────────────────────────────────────────

  # Fresh oneshot dispatch — fiber on disk, run-script verified byte-level.
  # Exercises the full path: disk read via real felt, agent resolution,
  # tmux invocation, run-script construction.
  test "fresh dispatch reads fiber from disk and embeds fiber id in run-script", %{host: host} do
    write_fiber(host, "tests/fresh-oneshot", """
    ---
    name: Fresh oneshot test
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
    ---
    A fresh oneshot fiber.
    """)

    assert {:ok, "shuttle-tests/fresh-oneshot"} =
             Dispatcher.dispatch("tests/fresh-oneshot",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()

    # Banner: fiber id and agent embedded.
    assert script =~ "Shuttle worker — tests/fresh-oneshot"
    assert script =~ "agent=claude-sonnet"

    # Claude fresh dispatch: here-string syntax, fiber ID in prompt.
    assert script =~ "claude"
    assert script =~ "<<<"
    assert script =~ "Fiber: tests/fresh-oneshot"

    # Fresh dispatch: no resume flag, no dismiss block.
    refute script =~ "--resume"
    refute script =~ "send-keys"
  end

  # Closed fiber is refused before any tmux interaction.
  test "closed fiber is refused with :closed", %{host: host} do
    write_fiber(host, "tests/closed-fiber", """
    ---
    name: Closed fiber
    status: closed
    tags:
      - constitution
    shuttle:
      enabled: false
      kind: oneshot
    ---
    A closed fiber.
    """)

    assert {:error, :closed} =
             Dispatcher.dispatch("tests/closed-fiber",
               runner: IntegrationRunner,
               felt_store: host
             )

    # No tmux invocation.
    refute Enum.any?(IntegrationRunner.commands(), fn {cmd, _} -> cmd == "tmux" end)
  end

  # Already-running fiber is refused when its tmux session exists.
  test "already-running fiber is refused with :already_running", %{host: host} do
    write_fiber(host, "tests/running-fiber", """
    ---
    name: Running fiber
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
    ---
    A running fiber.
    """)

    # Pre-seed the tmux session to simulate a live worker.
    IntegrationRunner.add_tmux_session(Dispatcher.session_name("tests/running-fiber"))

    assert {:error, :already_running} =
             Dispatcher.dispatch("tests/running-fiber",
               runner: IntegrationRunner,
               felt_store: host
             )
  end

  # Unknown fiber is refused cleanly.
  test "unknown fiber is refused with :not_found", %{host: host} do
    assert {:error, :not_found} =
             Dispatcher.dispatch("tests/does-not-exist",
               runner: IntegrationRunner,
               felt_store: host
             )
  end

  # ── Resume path tests ──────────────────────────────────────────────────────

  # Hypothesis #1 confirmed: shuttle-ctl resume flips enabled=true but does NOT
  # file a `--kind review-comment` event. check_resume_intent reads only review-
  # comment events; without one, it returns :fresh, so even a fiber with a stored
  # shuttle.session.id gets a fresh worker.
  #
  # This test documents the current behavior *before* the lifecycle.go fix that
  # makes shuttle-ctl resume file the review-comment. After that fix lands,
  # test "CLI resume after fix: review-comment filed → --resume in run-script" below
  # should cover the green path.
  test "CLI resume: no review-comment → dispatcher takes fresh path despite session.id",
       %{host: host} do
    write_fiber(host, "tests/cli-resume-no-event", """
    ---
    name: CLI resume no event
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
      session:
        agent: claude-sonnet
        dispatched_at: "2026-05-01T09:00:00Z"
        id: test-session-uuid-abcd
    ---
    A fiber with a prior session but no review-comment filed by shuttle-ctl resume.
    """)

    # No review-comment event filed — this is what shuttle-ctl resume does today
    # (before the fix). The dispatcher has no resume signal.
    assert {:ok, _} =
             Dispatcher.dispatch("tests/cli-resume-no-event",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()
    # Takes fresh path: no --resume flag, no dismiss block.
    refute script =~ "--resume"
    refute script =~ "send-keys"
  end

  # After the lifecycle.go fix: shuttle-ctl resume files a review-comment with
  # resume_mode=previous, so the dispatcher takes the resume path.
  test "CLI resume after fix: review-comment filed → --resume in run-script", %{host: host} do
    write_fiber(host, "tests/cli-resume-fixed", """
    ---
    name: CLI resume fixed
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
      session:
        agent: claude-sonnet
        dispatched_at: "2026-05-01T09:00:00Z"
        id: cli-resume-session-uuid
    ---
    A fiber where shuttle-ctl resume has filed the review-comment.
    """)

    # Simulate what shuttle-ctl resume does after the fix: file a review-comment
    # with resume_mode=previous so the dispatcher knows to invoke --resume.
    append_review_comment(host, "tests/cli-resume-fixed",
      summary: "resumed via shuttle-ctl; session cli-resume-session-uuid available for reattach",
      resume_mode: "previous"
    )

    assert {:ok, _} =
             Dispatcher.dispatch("tests/cli-resume-fixed",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()
    assert script =~ "--resume 'cli-resume-session-uuid'"
    # Claude's dismiss-warning block is present on resume.
    assert script =~ "send-keys"
    assert script =~ "sleep 2"
  end

  # Kanban resume: review-comment with resume_mode=previous triggers claude --resume.
  # This path works today (kanban writes the review-comment correctly).
  test "kanban resume: review-comment with resume_mode=previous triggers --resume", %{host: host} do
    write_fiber(host, "tests/kanban-resume", """
    ---
    name: Kanban resume fiber
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
      session:
        agent: claude-sonnet
        dispatched_at: "2026-05-01T09:00:00Z"
        id: kanban-session-uuid-5678
    ---
    A fiber that the kanban resumes.
    """)

    # Kanban writes a review-comment on "Resume previous" click.
    append_review_comment(host, "tests/kanban-resume",
      summary: "Continue from where we left off",
      resume_mode: "previous"
    )

    assert {:ok, _} =
             Dispatcher.dispatch("tests/kanban-resume",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()
    assert script =~ "--resume 'kanban-session-uuid-5678'"
    # Claude's resume warning dismiss block is present.
    assert script =~ "send-keys"
    assert script =~ "sleep 2"
    # Resume prompt (not fresh dispatch prompt) is in the script.
    assert script =~ "Shuttle resumed your previous session"
    assert script =~ "Fiber: tests/kanban-resume"
  end

  # Resume mode requested but no session UUID: falls back to fresh cleanly.
  test "resume mode requested but no session UUID falls back to fresh", %{host: host} do
    write_fiber(host, "tests/resume-no-uuid", """
    ---
    name: Resume no UUID
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
    ---
    No session UUID in shuttle block.
    """)

    # review-comment says resume, but there's no UUID stored.
    append_review_comment(host, "tests/resume-no-uuid",
      summary: "Please resume",
      resume_mode: "previous"
    )

    assert {:ok, _} =
             Dispatcher.dispatch("tests/resume-no-uuid",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()
    # Falls back to fresh: no --resume, no dismiss block.
    refute script =~ "--resume"
    refute script =~ "send-keys"
  end

  # review-comment with resume_mode=fresh explicitly requests a new session
  # even when a prior session UUID is stored.
  test "resume_mode=fresh takes fresh path even with stored session.id", %{host: host} do
    write_fiber(host, "tests/resume-mode-fresh", """
    ---
    name: Resume mode fresh
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
      session:
        agent: claude-sonnet
        dispatched_at: "2026-05-01T09:00:00Z"
        id: should-not-be-resumed-uuid
    ---
    Session exists but resume_mode explicitly says fresh.
    """)

    append_review_comment(host, "tests/resume-mode-fresh",
      summary: "Start fresh please",
      resume_mode: "fresh"
    )

    assert {:ok, _} =
             Dispatcher.dispatch("tests/resume-mode-fresh",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()
    refute script =~ "--resume"
    refute script =~ "send-keys"
  end

  # ── Standing role dispatch ─────────────────────────────────────────────────

  # Standing role with prompt_context: {:standing_run, run_id} uses
  # render_standing_run_prompt: "scheduled run of this standing role", run id,
  # and the awaiting-review framing — NOT the fresh-dispatch orientation.
  test "standing role dispatch embeds run-id and standing framing in prompt", %{host: host} do
    write_fiber(host, "tests/standing-dispatch", """
    ---
    name: Standing dispatch test
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: standing
      agent: claude-sonnet
      schedule:
        expr: "0 9 * * 1-5"
      review:
        state: scheduled
      next_due_at: "2026-05-01T09:00:00Z"
    ---
    A standing role fiber.
    """)

    assert {:ok, _} =
             Dispatcher.dispatch("tests/standing-dispatch",
               runner: IntegrationRunner,
               felt_store: host,
               prompt_context: {:standing_run, "run-2026-05-07"}
             )

    script = read_run_script()
    # Standing-role framing.
    assert script =~ "scheduled run of this standing role"
    assert script =~ "one due occurrence"
    assert script =~ "Fiber: tests/standing-dispatch"
    assert script =~ "run-2026-05-07"
    # NOT the fresh-dispatch orientation paragraph.
    refute script =~ "The orchestration system Shuttle dispatched you on this fiber"
  end

  # ── User message block ─────────────────────────────────────────────────────

  # A review-comment with a non-empty summary surfaces as the "From User" block
  # in the dispatch prompt, so the worker sees the directive at the top of context.
  test "review-comment summary appears as From User block in fresh dispatch prompt",
       %{host: host} do
    write_fiber(host, "tests/user-message", """
    ---
    name: User message fiber
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
    ---
    A fiber with a user directive.
    """)

    append_review_comment(host, "tests/user-message",
      summary: "Focus on the authentication layer first",
      resume_mode: "fresh"
    )

    assert {:ok, _} =
             Dispatcher.dispatch("tests/user-message",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()
    assert script =~ "From User"
    assert script =~ "Focus on the authentication layer first"
  end

  # No review-comment at all suppresses the From User block. The common case
  # for a fresh constitution that has never been requeued from the kanban.
  test "no review-comment event suppresses From User block", %{host: host} do
    write_fiber(host, "tests/no-review-comment", """
    ---
    name: No review comment fiber
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
    ---
    A fresh fiber with no kanban interactions yet.
    """)

    # No append_review_comment call — fiber has no history events at all.
    assert {:ok, _} =
             Dispatcher.dispatch("tests/no-review-comment",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()
    refute script =~ "From User"
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Mirror of Go lifecycle_test.go's withTempHost: creates a temp directory
  # with a .felt/ subdirectory so `felt -C <host> show <id>` can find fibers.
  defp mk_tmp_felt_store do
    host =
      Path.join(System.tmp_dir!(), "shuttle-inttest-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(host, ".felt"))
    host
  end

  # Mirror of Go lifecycle_test.go's writeFiber: writes a fiber markdown file
  # at host/.felt/<id segments>/<basename>.md so `felt show --json` can find it.
  defp write_fiber(host, id, content) do
    parts = String.split(id, "/")
    basename = List.last(parts)
    dir = Path.join([host, ".felt"] ++ parts)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{basename}.md"), String.trim(content) <> "\n")
  end

  # Appends a review-comment event to the fiber's felt history so that
  # check_resume_intent/3 and render_user_message_block/2 can read it.
  defp append_review_comment(host, id, opts) do
    summary = Keyword.get(opts, :summary, "Requeued")
    resume_mode = Keyword.get(opts, :resume_mode)

    args =
      ["-C", host, "history", "append", id, "--kind", "review-comment", "-m", summary] ++
        if(resume_mode, do: ["--field", "resume_mode=#{resume_mode}"], else: [])

    {out, code} = System.cmd("felt", args, stderr_to_stdout: true)
    if code != 0, do: raise("felt history append failed (#{code}): #{out}")
  end

  # Finds the tmux new-session command recorded by IntegrationRunner and reads
  # the run-script tempfile that was passed to `bash -l`. The script contains
  # the agent command, banners, and (for resume) the dismiss block.
  defp read_run_script do
    {_, args} =
      IntegrationRunner.commands()
      |> Enum.find(fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)

    File.read!(List.last(args))
  end
end
