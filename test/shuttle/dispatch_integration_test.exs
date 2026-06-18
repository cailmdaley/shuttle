defmodule Shuttle.DispatchIntegrationTest do
  use ExUnit.Case, async: false

  alias Shuttle.{Dispatcher, Poller}

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
      if tmux_session_exists?(sessions, session), do: {"", 0}, else: {"can't find session", 1}
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

    defp tmux_session_exists?(sessions, "=" <> session), do: MapSet.member?(sessions, session)

    defp tmux_session_exists?(sessions, session) do
      Enum.any?(sessions, &(&1 == session or String.starts_with?(&1, session <> "/")))
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

    assert {:ok, "fresh-oneshot-shuttle"} =
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
      kind: oneshot
      agent: claude-sonnet
    ---
    A fiber where shuttle-ctl resume has filed the review-comment.
    """)

    # The prior session id lives in felt history (slice 6: no doc-resident
    # session block); the dispatcher parses it back via extract_session_id.
    append_worker_exit(host, "tests/cli-resume-fixed",
      agent: "claude-sonnet",
      session: "cli-resume-session-uuid"
    )

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
      kind: oneshot
      agent: claude-sonnet
    ---
    A fiber that the kanban resumes.
    """)

    # The prior session id lives in felt history (slice 6).
    append_worker_exit(host, "tests/kanban-resume",
      agent: "claude-sonnet",
      session: "kanban-session-uuid-5678"
    )

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

  test "kanban resume uses worker-exit history session when frontmatter session was cleared", %{
    host: host
  } do
    write_fiber(host, "tests/kanban-history-resume", """
    ---
    name: Kanban history resume fiber
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: codex
    ---
    A codex fiber whose live session block has been cleared.
    """)

    append_worker_exit(host, "tests/kanban-history-resume",
      agent: "codex",
      session: "40740310-2345-4e33-a1e4-7950db41ce10"
    )

    append_review_comment(host, "tests/kanban-history-resume",
      summary: "Continue from history",
      resume_mode: "previous"
    )

    assert {:ok, _} =
             Dispatcher.dispatch("tests/kanban-history-resume",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()
    assert script =~ "codex"
    assert script =~ "resume '40740310-2345-4e33-a1e4-7950db41ce10'"
    assert script =~ "Shuttle resumed your previous session"
  end

  test "poller resume recovers the session id from felt history", %{
    host: host
  } do
    write_fiber(host, "tests/poller-history-resume", """
    ---
    name: Poller history resume fiber
    status: active
    tags:
      - constitution
    shuttle:
      kind: oneshot
      agent: claude-sonnet
      host: test-host
    ---
    A fiber whose resume handle lives only in felt history (slice 6).
    """)

    append_worker_exit(host, "tests/poller-history-resume",
      agent: "claude-sonnet",
      session: "history-resume-session-uuid"
    )

    append_review_comment(host, "tests/poller-history-resume",
      summary: "Continue from the history handle",
      resume_mode: "previous"
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_history_resume,
        runner: IntegrationRunner,
        poll_interval_ms: 600_000,
        felt_stores: [host]
      )

    assert {:ok, _} =
             Poller.dispatch_fiber(poller, "tests/poller-history-resume", [])

    script = read_run_script()
    assert script =~ "--resume 'history-resume-session-uuid'"
    assert script =~ "Shuttle resumed your previous session"
  end

  test "session id is recovered when a redispatch storm buries the dispatch event", %{
    host: host
  } do
    # Regression: a human-led oneshot left `status: active` gets redispatched
    # every poll; each worker exits :normal_exit and `log_worker_exit` appends a
    # SESSION-LESS "worker exited" event. The session id lives only in the rare
    # "worker dispatched ... session=<uuid>" event, which a fixed `--last N`
    # history window buries once enough exit events pile up — the resume lookup
    # then returns nil → :missing_session_id → the fiber blocks indefinitely
    # ("in-flight but never aloft"). The lookup must scan all of history.
    write_fiber(host, "tests/storm-buried-session", """
    ---
    name: Storm-buried session fiber
    status: active
    tags:
      - constitution
    shuttle:
      kind: oneshot
      agent: claude-opus
      host: test-host
    ---
    A human-led oneshot whose one dispatch event is buried under an exit storm.
    """)

    append_dispatch_event(host, "tests/storm-buried-session",
      agent: "claude-opus",
      session: "buried-session-uuid"
    )

    # The storm: production-shaped, session-less exit events (mirrors
    # `log_worker_exit`, which logs agent= only). Far more than any fixed window.
    for _ <- 1..30 do
      append_freeform_exit(
        host,
        "tests/storm-buried-session",
        "worker exited (:normal_exit); agent=claude-opus"
      )
    end

    append_review_comment(host, "tests/storm-buried-session",
      summary: "Resume previous",
      resume_mode: "previous"
    )

    assert {:ok, _} =
             Dispatcher.dispatch("tests/storm-buried-session",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()
    assert script =~ "--resume 'buried-session-uuid'"
    refute script =~ "missing_session_id"
  end

  test "resume previous dispatch reaches each harness-specific resume command", %{host: host} do
    matrix = [
      {"claude-sonnet", "claude-session-111", ["claude", "--resume 'claude-session-111'", "<<<"],
       ["codex resume", "pi "]},
      {"codex", "codex-session-222",
       ["codex", "resume 'codex-session-222'", "Shuttle resumed your previous session"],
       ["--resume", "--session"]},
      {"pi-kimi", "pi-session-333", ["pi", "--session 'pi-session-333'"],
       ["--resume", "Shuttle resumed your previous session"]}
    ]

    for {agent, session_id, expected, forbidden} <- matrix do
      IntegrationRunner.reset(host)
      id = "tests/resume-matrix/#{agent}"

      write_resume_fiber(host, id,
        agent: agent,
        history_session: session_id
      )

      append_review_comment(host, id,
        summary: "Resume the previous #{agent} worker",
        resume_mode: "previous"
      )

      assert {:ok, _} =
               Dispatcher.dispatch(id,
                 runner: IntegrationRunner,
                 felt_store: host
               )

      script = read_run_script()
      for needle <- expected, do: assert(script =~ needle)
      for needle <- forbidden, do: refute(script =~ needle)
    end
  end

  test "resume previous can recover the session id from worker-exit history for every harness", %{
    host: host
  } do
    matrix = [
      {"claude-sonnet", "claude-history-session", "--resume 'claude-history-session'"},
      {"codex", "codex-history-session", "resume 'codex-history-session'"},
      {"pi-kimi", "pi-history-session", "--session 'pi-history-session'"}
    ]

    for {agent, session_id, resume_fragment} <- matrix do
      IntegrationRunner.reset(host)
      id = "tests/history-resume-matrix/#{agent}"

      write_resume_fiber(host, id, agent: agent)
      append_worker_exit(host, id, agent: agent, session: session_id)

      append_review_comment(host, id,
        summary: "Resume from history for #{agent}",
        resume_mode: "previous"
      )

      assert {:ok, _} =
               Dispatcher.dispatch(id,
                 runner: IntegrationRunner,
                 felt_store: host
               )

      assert read_run_script() =~ resume_fragment
    end
  end

  test "codex session capture ignores newer non-worker session in same cwd", %{host: host} do
    session_dir = Path.join(host, "codex-sessions")
    File.mkdir_p!(session_dir)

    previous_dir = System.get_env("SHUTTLE_CODEX_SESSIONS_DIR")
    System.put_env("SHUTTLE_CODEX_SESSIONS_DIR", session_dir)

    on_exit(fn ->
      if previous_dir do
        System.put_env("SHUTTLE_CODEX_SESSIONS_DIR", previous_dir)
      else
        System.delete_env("SHUTTLE_CODEX_SESSIONS_DIR")
      end
    end)

    work_dir = File.cwd!()
    timestamp = DateTime.utc_now() |> DateTime.add(30, :second) |> DateTime.to_iso8601()

    write_codex_session(
      session_dir,
      "rollout-2999-01-01T00-00-01-zzzz-newer-wrong.jsonl",
      "wrong-human-session",
      work_dir,
      timestamp,
      "Fiber: tests/some-other-fiber"
    )

    write_codex_session(
      session_dir,
      "rollout-2999-01-01T00-00-00-aaaa-worker.jsonl",
      "right-worker-session",
      work_dir,
      timestamp,
      "Fiber: tests/codex-capture"
    )

    write_fiber(host, "tests/codex-capture", """
    ---
    name: Codex capture test
    status: active
    tags:
      - constitution
    shuttle:
      kind: oneshot
      agent: codex
    ---
    A codex fiber whose session UUID should be captured from its own transcript.
    """)

    assert {:ok, "codex-capture-shuttle"} =
             Dispatcher.dispatch("tests/codex-capture",
               runner: IntegrationRunner,
               felt_store: host,
               work_dir: work_dir
             )

    # The captured worker session id is recorded in felt history (slice 6:
    # the only durable session-id home), carrying the `session=<uuid>` token the
    # dispatcher parses back at resume. The wrong (human) session is ignored.
    assert eventually(fn -> history_text(host, "tests/codex-capture") =~ "session=right-worker-session" end)
    refute history_text(host, "tests/codex-capture") =~ "wrong-human-session"
  end

  # Interactivity is retired as a dispatch mode: the prompt never renders an
  # "Interactive Mode" block, and a legacy `interactive: true` still sitting in a
  # fiber is inert — the worker reads the always-autonomous exit contract and
  # honors any "wait for me" intent from the From User directive instead.
  test "dispatch prompt stays autonomous and renders no Interactive Mode block, even with a legacy interactive flag",
       %{host: host} do
    write_fiber(host, "tests/legacy-interactive-flag", """
    ---
    name: Legacy interactive flag
    status: active
    tags:
      - constitution
    shuttle:
      kind: oneshot
      agent: claude-sonnet
      interactive: true
    ---
    A fiber carrying a retired interactive flag.
    """)

    assert {:ok, _} =
             Dispatcher.dispatch("tests/legacy-interactive-flag",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()
    refute script =~ "Interactive Mode"
    assert script =~ "Exit Contract"
    assert script =~ "autonomous Shuttle worker"
  end

  # A "talk to me first" directive rides the From User block (the channel the
  # kanban "wait for me" affordance prepends to) — the worker reads it at the top
  # of context and waits, no dispatch-mode flag involved.
  test "a talk-first From User directive surfaces in the dispatch prompt", %{host: host} do
    write_fiber(host, "tests/talk-first", """
    ---
    name: Talk first
    status: active
    tags:
      - constitution
    shuttle:
      kind: oneshot
      agent: claude-sonnet
    ---
    A fiber whose dispatch should wait for the human.
    """)

    append_review_comment(host, "tests/talk-first",
      summary: "Wait for me before doing anything heavy — let's talk first."
    )

    assert {:ok, _} =
             Dispatcher.dispatch("tests/talk-first",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()
    assert script =~ "From User"
    assert script =~ "talk first"
  end

  # Resume mode requested but no session UUID: fail loudly. "New session" is
  # the explicit fresh path; Resume should never silently dispatch fresh.
  test "resume mode requested but no session UUID errors instead of dispatching fresh", %{
    host: host
  } do
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

    assert {:error, :missing_session_id} =
             Dispatcher.dispatch("tests/resume-no-uuid",
               runner: IntegrationRunner,
               felt_store: host
             )
  end

  # Scheduled standing-run dispatches scope the review-comment lookup to the
  # current run window — the window opens at the LAST worker-exit event in felt
  # history (slice 4: not parsed from the prompt's run_id). A resume directive
  # filed BEFORE that exit is from a prior run cycle and is ignored. Without
  # this, a stale `resume_mode: "previous"` from days ago blocks every
  # subsequent scheduled run with :missing_session_id. (Real-world example:
  # loom/email/morning-post stuck 2026-05-09 → 2026-05-14 with no surfaced
  # signal; the warning log fired every 30s for 5 days.)
  test "scheduled standing-run ignores a resume directive older than the last worker exit",
       %{host: host} do
    write_fiber(host, "tests/standing-stale-resume", """
    ---
    name: Standing stale resume
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: standing
      agent: claude-sonnet
      schedule:
        expr: 0 9 * * 1-5
        tz: Europe/Paris
    ---
    Standing role with a stale resume directive.
    """)

    # A resume directive from a PRIOR run cycle (resume_mode: previous, no
    # session id) ...
    append_review_comment(host, "tests/standing-stale-resume",
      summary: "Resume previous",
      resume_mode: "previous"
    )

    # ... followed by a later worker-exit, which opens the current run window
    # AFTER the directive. The directive is therefore outside the window and is
    # ignored → :fresh.
    append_worker_exit(host, "tests/standing-stale-resume",
      agent: "claude-sonnet",
      session: "11111111-2222-3333-4444-555555555555"
    )

    assert {:ok, _} =
             Dispatcher.dispatch("tests/standing-stale-resume",
               runner: IntegrationRunner,
               felt_store: host,
               prompt_context: {:standing_run, "29990101T090000+0000"}
             )

    script = read_run_script()
    # Fresh path: no --resume flag, no dismiss block.
    refute script =~ "--resume"
    refute script =~ "send-keys"
  end

  # Inverse of the above: when the review-comment is filed AFTER the last
  # worker-exit, it falls inside the current run window and the existing
  # fail-loud-on-missing-session contract still holds.
  test "scheduled standing-run honors a resume directive filed after the last worker exit",
       %{host: host} do
    write_fiber(host, "tests/standing-fresh-resume", """
    ---
    name: Standing fresh resume
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: standing
      agent: claude-sonnet
      schedule:
        expr: 0 9 * * 1-5
        tz: Europe/Paris
    ---
    Standing role with an in-window resume directive but no session id.
    """)

    # The window opens at this worker-exit ...
    append_worker_exit(host, "tests/standing-fresh-resume",
      agent: "claude-sonnet",
      session: "<unknown>"
    )

    # ... and the resume directive is filed after it, so it applies. No usable
    # session id → fail loud per the existing contract.
    append_review_comment(host, "tests/standing-fresh-resume",
      summary: "Resume previous",
      resume_mode: "previous"
    )

    assert {:error, :missing_session_id} =
             Dispatcher.dispatch("tests/standing-fresh-resume",
               runner: IntegrationRunner,
               felt_store: host,
               prompt_context: {:standing_run, "20200101T090000+0000"}
             )
  end

  test "poller dispatch API preserves missing session UUID errors", %{host: host} do
    write_fiber(host, "tests/poller-resume-no-uuid", """
    ---
    name: Poller resume no UUID
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
      host: test-host
    ---
    No session UUID in shuttle block.
    """)

    append_review_comment(host, "tests/poller-resume-no-uuid",
      summary: "Please resume",
      resume_mode: "previous"
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_resume_no_uuid,
        runner: IntegrationRunner,
        poll_interval_ms: 600_000,
        felt_stores: [host]
      )

    assert {:error, :missing_session_id} =
             Poller.dispatch_fiber(poller, "tests/poller-resume-no-uuid", [])

    refute Enum.any?(IntegrationRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and Enum.at(args, 0) == "new-session"
           end)

    # The dispatch failure surfaces in the snapshot's `blocked` list so the
    # kanban shows *why* the fiber isn't progressing. Before this, the only
    # signal was a warning log that scrolled by once every 30s.
    snap = Poller.snapshot(poller)

    assert [%{fiber_id: "tests/poller-resume-no-uuid", reason: "missing_session_id"} = entry] =
             snap.blocked

    assert entry.attempts == 1
    assert is_integer(entry.attempted_at)
    assert is_integer(entry.first_attempted_at)
  end

  # The poll cycle evicts dispatch_failures entries when the underlying fiber
  # is no longer discoverable (closed, paused, or had its shuttle block
  # removed). Without eviction, the snapshot would carry stale "blocked"
  # entries the user has no remaining handle on.
  test "blocked entry clears when fiber is closed", %{host: host} do
    write_fiber(host, "tests/blocked-then-closed", """
    ---
    name: Blocked then closed
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
      host: test-host
    ---
    No session UUID; dispatch will block.
    """)

    append_review_comment(host, "tests/blocked-then-closed",
      summary: "Please resume",
      resume_mode: "previous"
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_blocked_then_closed,
        runner: IntegrationRunner,
        poll_interval_ms: 600_000,
        felt_stores: [host]
      )

    assert {:error, :missing_session_id} =
             Poller.dispatch_fiber(poller, "tests/blocked-then-closed", [])

    assert [%{fiber_id: "tests/blocked-then-closed"}] = Poller.snapshot(poller).blocked

    # Close the fiber. The next poll cycle's candidate set no longer
    # contains it, so the dispatch-failure entry should evict.
    {_out, 0} =
      System.cmd("felt", ["-C", host, "edit", "tests/blocked-then-closed", "--status", "closed"],
        stderr_to_stdout: true
      )

    send(poller, :run_poll_cycle)

    assert eventually(fn -> Poller.snapshot(poller).blocked == [] end),
           "expected blocked entry to evict after fiber closed"
  end

  # Slice-6 standing dead-orphan reconciler on the tmux-scan substrate. A standing
  # worker that exits while the daemon is DOWN never fires handle_worker_exit, so
  # the armed document would re-fire. On poll, the daemon scans tmux: an armed
  # standing role with no live session whose felt history shows a trailing "worker
  # dispatched" with no "worker exited" after it (the daemon-down-across-exit
  # case) is marked awaiting (status:closed). The felt-history discriminator
  # replaces slice 1's runtime-store session.id check (slice 6: no runtime store).
  # A role whose last run already exited (the daily-practice "armed, not-yet-due,
  # never-dispatched-this-cycle" shape) is left armed, proven by the sibling.
  test "a standing role with an un-exited dispatch is marked awaiting; one whose run exited is left armed",
       %{host: host} do
    # The dead worker's role — armed, no live session, with a trailing un-exited
    # "worker dispatched" event in history (the daemon-down case).
    write_fiber(host, "tests/standing-dead", """
    ---
    name: Standing dead-orphan
    status: active
    tags:
      - constitution
      - standing
    shuttle:
      kind: standing
      agent: claude-sonnet
      host: test-host
      schedule:
        expr: "0 8 * * *"
        tz: Europe/Paris
    ---
    A standing role whose worker died while the daemon was down.
    """)

    append_dispatch_event(host, "tests/standing-dead",
      agent: "claude-sonnet",
      session: "dead-session-uuid"
    )

    # The control — armed, whose last run already exited (its dispatch is
    # followed by an exit). Must be left untouched: the run completed, this is the
    # next cycle's armed-and-waiting shape.
    write_fiber(host, "tests/standing-armed", """
    ---
    name: Standing armed (last run exited)
    status: active
    tags:
      - constitution
      - standing
    shuttle:
      kind: standing
      agent: claude-sonnet
      host: test-host
      schedule:
        expr: "0 8 * * *"
        tz: Europe/Paris
    ---
    A standing role whose previous run completed; armed for the next tick.
    """)

    append_dispatch_event(host, "tests/standing-armed",
      agent: "claude-sonnet",
      session: "completed-session-uuid"
    )

    append_worker_exit(host, "tests/standing-armed",
      agent: "claude-sonnet",
      session: "completed-session-uuid"
    )

    # mark_awaiting resolves the fiber through FeltStores (LOOM_HOMES), not the
    # injected runner — point it at the temp store for the duration.
    prev_loom = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", host)

    try do
      {:ok, _poller} =
        Poller.start_link(
          name: :test_poller_standing_dead_orphan,
          runner: IntegrationRunner,
          poll_interval_ms: 600_000,
          felt_stores: [host]
        )

      # The dead role flips to awaiting (status:closed, untempered, closed-at).
      assert eventually(fn ->
               fm = read_frontmatter(host, "tests/standing-dead")
               fm["status"] == "closed"
             end),
             "expected the dead standing role to be marked awaiting (status:closed)"

      dead_fm = read_frontmatter(host, "tests/standing-dead")
      refute Map.has_key?(dead_fm, "tempered")
      assert is_binary(dead_fm["closed-at"])

      # The control role, whose last run exited, stays armed — the reconciler does
      # not regress a role whose run already completed.
      assert read_frontmatter(host, "tests/standing-armed")["status"] == "active"
    after
      if prev_loom, do: System.put_env("LOOM_HOMES", prev_loom), else: System.delete_env("LOOM_HOMES")
    end
  end

  # A standing role whose last dispatch was followed by a free-form worker exit
  # summary (no canonical "worker exited" marker) AND a human accept must be left
  # armed — the human's accept supersedes the dead-orphan inference. Regression
  # for the real morning-post / weekly-arxiv oscillation: interactive/ad-hoc runs
  # the daemon didn't observe exiting wrote only a free-form summary, so the
  # dead-orphan reconciler walked past it to the "worker dispatched" event and
  # re-closed the role to awaiting on every restart/reconcile, undoing each
  # accept.
  #
  # The CONTROL role (dispatch + free-form exit, NO accept) flips to awaiting in
  # the same poll — proving the reconciler actually ran this cycle, so the
  # accepted role staying active is the fix at work, not a reconcile that never
  # fired.
  test "an accepted standing role is left armed despite a non-canonical exit summary",
       %{host: host} do
    for {slug, accept?} <- [{"standing-accepted-freeform", true}, {"standing-dead-freeform", false}] do
      write_fiber(host, "tests/#{slug}", """
      ---
      name: #{slug}
      status: active
      tags:
        - constitution
        - standing
      shuttle:
        kind: standing
        agent: claude-sonnet
        host: test-host
        schedule:
          expr: "0 8 * * *"
          tz: Europe/Paris
      ---
      A standing role with a free-form (non-canonical) exit summary.
      """)

      # Dispatch, then a FREE-FORM exit summary (no "worker exited").
      append_dispatch_event(host, "tests/#{slug}", agent: "claude-fable", session: "#{slug}-uuid")

      append_freeform_exit(host, "tests/#{slug}",
        "Ad-hoc interactive run adhoc-123 complete; inbox at intended residue."
      )

      # Only the fix-target role gets the human accept after the exit.
      if accept?, do: append_accept_event(host, "tests/#{slug}")
    end

    prev_loom = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", host)

    try do
      {:ok, _poller} =
        Poller.start_link(
          name: :test_poller_accepted_freeform,
          runner: IntegrationRunner,
          poll_interval_ms: 600_000,
          felt_stores: [host]
        )

      # CONTROL: a dispatched-and-exited-but-never-accepted role flips to awaiting
      # — this proves the dead-orphan reconciler ran on this candidate set.
      assert eventually(fn ->
               read_frontmatter(host, "tests/standing-dead-freeform")["status"] == "closed"
             end),
             "expected the un-accepted control role to be marked awaiting (proves reconcile ran)"

      # FIX: the accepted role — same free-form exit, plus a human accept — stays
      # armed. The accept supersedes the dead-orphan inference.
      fm = read_frontmatter(host, "tests/standing-accepted-freeform")
      assert fm["status"] == "active",
             "an accepted role must stay armed, not be re-marked awaiting by the dead-orphan reconciler"
      refute Map.has_key?(fm, "closed-at")
    after
      if prev_loom, do: System.put_env("LOOM_HOMES", prev_loom), else: System.delete_env("LOOM_HOMES")
    end
  end

  # The board's "New session" / "Resume" / drag-to-inFlight buttons force-dispatch
  # (force+ad_hoc) an awaiting standing role. The forced path must re-arm the doc
  # to status:active AS it spawns — one snappy action, no waiting on the 15s poll,
  # no running-worker-on-an-awaiting-card incoherence. Regression for the kanban
  # "New session refused with awaiting_review" bug.
  test "forced ad-hoc dispatch re-arms an awaiting standing role to active", %{host: host} do
    write_fiber(host, "tests/standing-awaiting-rearm", """
    ---
    name: Standing awaiting, force-dispatched
    status: closed
    closed-at: "2026-05-24T10:00:00Z"
    tags:
      - constitution
      - standing
    shuttle:
      kind: standing
      agent: claude-sonnet
      host: test-host
      schedule:
        expr: "0 9 * * 1-5"
        tz: Europe/Paris
    ---
    A standing role awaiting review; the human clicks New session.
    """)

    prev_loom = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", host)

    try do
      {:ok, poller} =
        Poller.start_link(
          name: :test_poller_force_rearm,
          runner: IntegrationRunner,
          poll_interval_ms: 600_000,
          felt_stores: [host]
        )

      # Let the first poll warm the document cache (card status comes from here).
      assert eventually(fn ->
               case Poller.cached_fiber_documents(poller) do
                 {:ok, body} ->
                   Enum.any?(body.fibers, &(get_in(&1, [:fiber, "id"]) == "tests/standing-awaiting-rearm"))

                 _ ->
                   false
               end
             end),
             "expected the document cache to warm with the awaiting role"

      # The forced board action bypasses the awaiting gate and spawns.
      assert {:ok, _session} =
               Poller.dispatch_fiber(poller, "tests/standing-awaiting-rearm",
                 force: true,
                 ad_hoc: true
               )

      # …and the doc is re-armed: status:active, closed-at cleared, untempered.
      fm = read_frontmatter(host, "tests/standing-awaiting-rearm")
      assert fm["status"] == "active"
      refute Map.has_key?(fm, "closed-at")
      refute Map.has_key?(fm, "tempered")

      # SNAPPY-NOW: the kanban's post-dispatch refetch reads card status from the
      # cached document feed. The shared post-mutation refresh (which the dispatch
      # endpoint calls right after Poller.dispatch_fiber) must make it report
      # active WITHOUT another poll — otherwise the card sits in "Awaiting review"
      # until the next tick even though the worker is live. No send(:run_poll_cycle).
      assert :ok = Poller.refresh_document(poller, "tests/standing-awaiting-rearm")
      assert {:ok, body} = Poller.cached_fiber_documents(poller)
      entry = Enum.find(body.fibers, &(get_in(&1, [:fiber, "id"]) == "tests/standing-awaiting-rearm"))
      assert entry, "re-armed role should still be in the owned feed"
      assert entry.fiber["status"] == "active"
      refute Map.has_key?(entry.fiber, "closed-at")
      refute Map.has_key?(entry.fiber, "tempered")
    after
      if prev_loom, do: System.put_env("LOOM_HOMES", prev_loom), else: System.delete_env("LOOM_HOMES")
    end
  end

  # Accepting an awaiting standing role re-arms it (status:active) for its NEXT
  # tick — it must NOT re-fire the occurrence that just ran. Regression for the
  # standing-role "temper oscillation": before the fix, accept flipped
  # closed→active while the just-served cron tick was still inside the ~90s
  # backward due-window, so the next poll re-dispatched it and the card popped
  # straight back to awaiting review. An every-minute schedule (always a tick in
  # the window) is the sharpest probe; the poller's rearm-instant clamp keeps it
  # at rest. Also asserts the second half of the fix: accept preserves the prior
  # run's outcome (no longer blanks it).
  test "accept re-arms a standing role without re-firing the just-served tick", %{host: host} do
    write_fiber(host, "tests/standing-temper-rest", """
    ---
    name: Standing temper-and-rest
    status: closed
    closed-at: "2026-05-24T10:00:00Z"
    outcome: "prior run digest — kept across accept"
    tags:
      - constitution
      - standing
    shuttle:
      kind: standing
      agent: claude-sonnet
      host: test-host
      schedule:
        expr: "* * * * *"
        tz: Europe/Paris
    ---
    A standing role awaiting review; the human drags it to tempered (accept).
    """)

    prev_loom = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", host)

    try do
      {:ok, poller} =
        Poller.start_link(
          name: :test_poller_temper_rest,
          runner: IntegrationRunner,
          poll_interval_ms: 600_000,
          felt_stores: [host]
        )

      assert eventually(fn ->
               case Poller.cached_fiber_documents(poller) do
                 {:ok, body} ->
                   Enum.any?(body.fibers, &(get_in(&1, [:fiber, "id"]) == "tests/standing-temper-rest"))

                 _ ->
                   false
               end
             end),
             "expected the document cache to warm with the awaiting role"

      # The kanban drag-to-tempered on a standing awaiting role resolves to accept.
      assert {:ok, _} = Poller.lifecycle_transition(poller, :accept, "tests/standing-temper-rest", [])

      # Re-armed AND the prior outcome survives (accept no longer blanks it).
      fm = read_frontmatter(host, "tests/standing-temper-rest")
      assert fm["status"] == "active"
      refute Map.has_key?(fm, "tempered")
      refute Map.has_key?(fm, "closed-at")
      assert fm["outcome"] == "prior run digest — kept across accept"

      # Now poll: the just-served tick must NOT re-fire. Clear recorded commands
      # so the assertion isolates this poll cycle's dispatch behavior.
      IntegrationRunner.reset(host)
      session = Dispatcher.session_name("tests/standing-temper-rest")
      send(poller, :run_poll_cycle)
      Process.sleep(150)

      refute Enum.any?(IntegrationRunner.commands(), fn {cmd, args} ->
               cmd == "tmux" and Enum.any?(args, &(&1 == session))
             end),
             "a freshly-accepted standing role must rest until its next tick, not re-fire the served one"

      # It stays armed-and-resting (active), not re-fired back to awaiting.
      assert read_frontmatter(host, "tests/standing-temper-rest")["status"] == "active"
    after
      if prev_loom, do: System.put_env("LOOM_HOMES", prev_loom), else: System.delete_env("LOOM_HOMES")
    end
  end

  # refresh_document/2 is the shared post-mutation seam every board action calls.
  # It must re-read ANY field change off disk (not just status) and evict a fiber
  # that no longer resolves — so the kanban refetch never snaps a card back to
  # stale cached state while waiting on the poll.
  test "refresh_document re-reads an out-of-band doc change and evicts a vanished fiber",
       %{host: host} do
    write_fiber(host, "tests/refresh-seam", """
    ---
    name: Refresh seam fiber
    status: active
    outcome: original outcome
    tags:
      - constitution
    shuttle:
      kind: oneshot
      agent: claude-sonnet
      host: test-host
    ---
    A fiber whose doc changes out of band.
    """)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_refresh_seam,
        runner: IntegrationRunner,
        poll_interval_ms: 600_000,
        felt_stores: [host]
      )

    assert eventually(fn ->
             case Poller.cached_fiber_documents(poller) do
               {:ok, body} -> Enum.any?(body.fibers, &(get_in(&1, [:fiber, "id"]) == "tests/refresh-seam"))
               _ -> false
             end
           end),
           "expected the document cache to warm"

    # Mutate a NON-status field out of band, then refresh — no poll cycle.
    write_fiber(host, "tests/refresh-seam", """
    ---
    name: Refresh seam fiber
    status: active
    outcome: changed outcome
    tags:
      - constitution
    shuttle:
      kind: oneshot
      agent: claude-sonnet
      host: test-host
    ---
    A fiber whose doc changes out of band.
    """)

    assert :ok = Poller.refresh_document(poller, "tests/refresh-seam")
    assert {:ok, body} = Poller.cached_fiber_documents(poller)
    entry = Enum.find(body.fibers, &(get_in(&1, [:fiber, "id"]) == "tests/refresh-seam"))
    assert entry.fiber["outcome"] == "changed outcome"

    # Delete the fiber on disk; refresh evicts it from the feed (no poll).
    File.rm_rf!(Path.join([host, ".felt", "tests", "refresh-seam"]))
    assert :ok = Poller.refresh_document(poller, "tests/refresh-seam")
    assert {:ok, body} = Poller.cached_fiber_documents(poller)
    refute Enum.any?(body.fibers, &(get_in(&1, [:fiber, "id"]) == "tests/refresh-seam"))
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

  # A review-comment already consumed by a prior run — i.e. followed by an
  # editorial (worker handoff) event — is suppressed on re-dispatch, so a stale
  # directive doesn't replay as a fresh task when the card is re-dispatched
  # without a new comment. Regression for the round-4-comment-resurfaced bug.
  test "review-comment older than the latest editorial event is suppressed", %{host: host} do
    write_fiber(host, "tests/consumed-message", """
    ---
    name: Consumed message fiber
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
    ---
    A fiber whose directive was already implemented by a prior run.
    """)

    # User files a directive, a worker runs and hands off (editorial event),
    # then the card is re-dispatched with no new comment.
    append_review_comment(host, "tests/consumed-message",
      summary: "Make the halo bigger",
      resume_mode: "fresh"
    )

    append_worker_exit(host, "tests/consumed-message",
      agent: "claude-sonnet",
      session: "sess-consumed"
    )

    assert {:ok, _} =
             Dispatcher.dispatch("tests/consumed-message",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()
    refute script =~ "From User"
    refute script =~ "Make the halo bigger"
  end

  # The inverse: a review-comment filed *after* the last editorial event (the
  # requeue-then-dispatch case) still renders — it hasn't been consumed yet.
  test "review-comment newer than the latest editorial event still renders", %{host: host} do
    write_fiber(host, "tests/fresh-after-handoff", """
    ---
    name: Fresh-after-handoff fiber
    status: active
    tags:
      - constitution
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
    ---
    A fiber with a prior run, then a brand-new directive.
    """)

    # A prior run handed off first, THEN the user filed a new directive.
    append_worker_exit(host, "tests/fresh-after-handoff",
      agent: "claude-sonnet",
      session: "sess-prior"
    )

    append_review_comment(host, "tests/fresh-after-handoff",
      summary: "Now restructure the talk order",
      resume_mode: "fresh"
    )

    assert {:ok, _} =
             Dispatcher.dispatch("tests/fresh-after-handoff",
               runner: IntegrationRunner,
               felt_store: host
             )

    script = read_run_script()
    assert script =~ "From User"
    assert script =~ "Now restructure the talk order"
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

  # Reads back a fiber's frontmatter from disk (host/.felt/<id>/<basename>.md),
  # the surface a daemon write like mark_awaiting lands on.
  defp read_frontmatter(host, id) do
    parts = String.split(id, "/")
    basename = List.last(parts)
    path = Path.join([host, ".felt"] ++ parts ++ ["#{basename}.md"])
    [_, fm, _] = File.read!(path) |> String.split("---", parts: 3)
    YamlElixir.read_from_string!(fm)
  end

  defp write_resume_fiber(host, id, opts) do
    agent = Keyword.fetch!(opts, :agent)
    history_session = Keyword.get(opts, :history_session)

    write_fiber(host, id, """
    ---
    name: Resume matrix #{agent}
    status: active
    tags:
      - constitution
    shuttle:
      kind: oneshot
      agent: #{agent}
    ---
    A fiber used by the resume matrix.
    """)

    # The session id lives in felt history (slice 6: no doc-resident session).
    if history_session do
      append_worker_exit(host, id, agent: agent, session: history_session)
    end
  end

  # Appends a review-comment event to the fiber's felt history so that
  # check_resume_intent/3 and render_user_message_block/2 can read it.
  defp append_review_comment(host, id, opts) do
    summary = Keyword.get(opts, :summary, "Requeued")
    resume_mode = Keyword.get(opts, :resume_mode)

    fields =
      []
      |> maybe_field("resume_mode", resume_mode)

    args =
      ["-C", host, "history", "append", id, "--kind", "review-comment", "-m", summary] ++
        fields

    {out, code} = System.cmd("felt", args, stderr_to_stdout: true)
    if code != 0, do: raise("felt history append failed (#{code}): #{out}")
  end

  defp maybe_field(fields, _key, nil), do: fields
  defp maybe_field(fields, key, value), do: fields ++ ["--field", "#{key}=#{value}"]

  # Raw felt-history text for a fiber, used to assert the dispatcher recorded the
  # session id (`session=<uuid>`) in history (slice 6: the durable session home).
  defp history_text(host, id) do
    case System.cmd("felt", ["-C", host, "history", id, "--last", "20"], stderr_to_stdout: true) do
      {out, 0} -> out
      _ -> ""
    end
  end

  defp append_worker_exit(host, id, opts) do
    agent = Keyword.fetch!(opts, :agent)
    session = Keyword.fetch!(opts, :session)
    summary = "worker exited (:normal_exit); agent=#{agent} session=#{session}"

    {out, code} =
      System.cmd("felt", ["-C", host, "history", "append", id, "-m", summary],
        stderr_to_stdout: true
      )

    if code != 0, do: raise("felt history append failed (#{code}): #{out}")
  end

  # Mirror the dispatcher's at-spawn session record (slice 6): a "worker
  # dispatched ... session=<uuid>" felt-history event, the durable session-id
  # home and the dead-orphan discriminator's "dispatched" marker.
  defp append_dispatch_event(host, id, opts) do
    agent = Keyword.fetch!(opts, :agent)
    session = Keyword.fetch!(opts, :session)
    summary = "worker dispatched (agent=#{agent}) session=#{session}"

    {out, code} =
      System.cmd("felt", ["-C", host, "history", "append", id, "-m", summary],
        stderr_to_stdout: true
      )

    if code != 0, do: raise("felt history append failed (#{code}): #{out}")
  end

  # A worker's own free-form exit summary (NOT the daemon's canonical "worker
  # exited ..." marker) followed by the human's accept — the real morning-post /
  # weekly-arxiv shape after an interactive/ad-hoc run the daemon didn't observe
  # exiting.
  defp append_freeform_exit(host, id, summary) do
    {out, code} =
      System.cmd("felt", ["-C", host, "history", "append", id, "-m", summary],
        stderr_to_stdout: true
      )

    if code != 0, do: raise("felt history append failed (#{code}): #{out}")
  end

  defp append_accept_event(host, id) do
    {out, code} =
      System.cmd("felt", ["-C", host, "history", "append", id, "-m", "accepted run for #{id}"],
        stderr_to_stdout: true
      )

    if code != 0, do: raise("felt history append failed (#{code}): #{out}")
  end

  defp write_codex_session(session_dir, filename, uuid, cwd, timestamp, prompt) do
    session_meta =
      Jason.encode!(%{
        "timestamp" => timestamp,
        "type" => "session_meta",
        "payload" => %{
          "id" => uuid,
          "timestamp" => timestamp,
          "cwd" => cwd
        }
      })

    user_turn =
      Jason.encode!(%{
        "timestamp" => timestamp,
        "type" => "response_item",
        "payload" => %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => prompt}]
        }
      })

    File.write!(Path.join(session_dir, filename), session_meta <> "\n" <> user_turn <> "\n")
  end

  defp eventually(fun, attempts \\ 40)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

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
