defmodule Shuttle.Dispatcher do
  @moduledoc """
  Dispatches a single worker for a felt constitution fiber.

  Reproduces the behavior of shuttle-worker.sh in Elixir:
  - Locates the fiber via felt CLI
  - Checks status (refuses closed)
  - Checks for existing tmux session
  - Creates tmux session with dispatch prompt
  - Invokes the resolved agent wrapper

  Stage 2: one-shot dispatch only. No poller, no watcher, no retry.
  """

  require Logger

  alias Shuttle.Agents
  import Bitwise

  @type dispatch_result ::
          {:ok, String.t()}
          | {:error, :not_found}
          | {:error, :closed}
          | {:error, :already_running}
          | {:error, String.t()}

  @doc """
  Dispatches a worker for the given fiber ID.

  Returns `{:ok, tmux_session_name}` on success, or an error tuple.

  Options:
    * `:runner` — module implementing `Shuttle.Runner` behavior for test injection.
      Defaults to `Shuttle.Runner.Default`.
    * `:work_dir` — working directory for the tmux session. Defaults to `File.cwd!()`.
    * `:felt_store` — directory containing the `.felt/` index this dispatch
      should read fibers and history from. Defaults to `default_felt_store/0`.
      The Poller passes its configured `state.felt_store` here so each shuttle
      instance is consistent within itself; running multiple shuttle instances
      against different felt stores (e.g. one for `~/loom`, another for a
      standalone project root) is the supported way to span felt stores.
    * `:prompt_context` — `:constitution` (default) or `:standing_run`.
  """
  @spec dispatch(String.t(), keyword()) :: dispatch_result()
  def dispatch(fiber_id, opts \\ []) do
    runner = Keyword.get(opts, :runner, Shuttle.Runner.Default)
    work_dir = Keyword.get(opts, :work_dir, File.cwd!())
    prompt_context = Keyword.get(opts, :prompt_context, :constitution)
    felt_store = Keyword.get(opts, :felt_store, default_felt_store())

    with {:ok, fiber} <- fetch_fiber(fiber_id, runner, felt_store: felt_store),
         :ok <- check_not_closed(fiber),
         :ok <- check_not_running(fiber_id, runner),
         {:ok, agent} <- resolve_agent(fiber),
         :ok <- validate_agent(agent) do
      # Human-worker no-op: when the fiber's agent is `human`, the user is
      # working on it themselves; Shuttle has nothing to dispatch. Return a
      # sentinel so the caller (Poller / DispatchController) can skip the
      # watcher / running-state plumbing without surfacing it as an error.
      if agent.id == "human" do
        Logger.info("Human-worker dispatch for #{fiber_id} — no tmux session spawned")
        {:ok, :human_no_op}
      else
        resume_intent = resolve_resume_intent(prompt_context, fiber_id, fiber, felt_store)

        create_tmux_session(fiber_id, agent, work_dir, runner, prompt_context, resume_intent,
          felt_store: felt_store
        )
      end
    end
  end

  @doc """
  Decides whether this dispatch should resume a prior worker session or start
  fresh, based on the prompt context.

  - Ad-hoc standing-role dispatches always start fresh. Resuming would land
    the worker in a transcript whose last assistant turn was "Run accepted.
    Exiting" — they'd idle ("nothing new on the fiber") instead of doing the
    new run.
  - All other contexts defer to `check_resume_intent/3`, which reads the
    most recent review-comment from felt history and honors its `resume_mode`.
  """
  @spec resolve_resume_intent(any(), String.t(), map(), String.t() | nil) ::
          :fresh | {:previous, String.t()}
  def resolve_resume_intent(prompt_context, fiber_id, fiber, felt_store) do
    case prompt_context do
      {:standing_run, _, :ad_hoc} ->
        :fresh

      _ ->
        opts = if is_nil(felt_store), do: [], else: [felt_store: felt_store]
        check_resume_intent(fiber_id, fiber, opts)
    end
  end

  @doc """
  Checks whether the most recent review-comment requests resume of the previous
  worker session and, if so, whether a stored session UUID is available.

  Returns one of:
  - `:fresh` — no resume requested, or no session UUID stored. Always the safe
    default: the worker gets a clean slate with the full dispatch prompt.
  - `{:previous, session_id}` — resume requested and session UUID available.
    The dispatcher will invoke the harness-appropriate resume command.

  Reads the latest `--kind review-comment` event from felt history. The
  `resume_mode` field in the event payload is set at requeue time by the user
  clicking "Requeue fresh" or "Resume previous" in the Kanban UI.
  """
  @spec check_resume_intent(String.t(), map(), keyword()) ::
          :fresh | {:previous, String.t()}
  def check_resume_intent(fiber_id, fiber, opts \\ []) do
    felt_store = Keyword.get(opts, :felt_store, default_felt_store())

    case query_history(fiber_id, ["--kind", "review-comment", "--last", "1", "--json"],
           felt_store: felt_store
         ) do
      [event | _] ->
        resume_mode = get_in(event, ["payload", "resume_mode"])

        session_id =
          get_in(fiber, ["shuttle", "session", "id"]) ||
            latest_history_session_id(fiber_id, felt_store: felt_store)

        if resume_mode == "previous" and is_binary(session_id) and session_id != "" do
          {:previous, session_id}
        else
          :fresh
        end

      _ ->
        :fresh
    end
  end

  @doc """
  Returns shuttle's default felt store.

  Mirrors `Shuttle.FeltStores.configured_hosts/0` and keeps `Dispatcher`
  working standalone (e.g. via the CLI) without a running Poller.
  """
  @spec default_felt_store() :: String.t()
  def default_felt_store do
    Shuttle.FeltStores.configured_hosts()
    |> List.first()
    |> Kernel.||(System.user_home() <> "/loom")
  end

  @doc """
  Renders the universal dispatch prompt for a fiber ID.

  The prompt opens with a single orientation paragraph — what Shuttle is,
  what the worker is here to do, and how the practice gets loaded — then
  inlines exactly one context block:

    - **From User** — the most recent `review-comment` event, if any.
      The user's intent for this dispatch. Persists across handoffs
      until a newer one is filed.

  We deliberately *don't* inline the fiber's outcome or the last
  editorial event. Both are already in scope after the worker calls
  `felt show <fiber-id>` (which renders outcome + the `Recent:` line)
  and `felt history <fiber-id>` (which renders the full editorial
  chain). The shuttle skill prescribes that read order; duplicating
  either here just bloats the prompt and risks drift between the
  inlined snapshot and felt's own view.

  Why keep the From User block inlined? The user's directive isn't
  recoverable from `felt show` in the same way — it's a typed event
  among many in the history, and having it sit at the top of the
  prompt where causal attention sees it first conditions the worker's
  reading of everything that follows.

  Operational instructions (read the constitution, exit before half-full,
  append an editorial event, `kill $PPID`) deliberately don't appear
  here — they're encoded in the `shuttle` skill the worker activates
  next. The prompt's job is orientation, not duplicating practice.

  On felt failure (binary missing, no history yet) the From User block
  falls back to empty — dispatch continues rather than failing, and
  the worker just gets the orientation header.

  ## Options

    * `:felt_store` — directory containing the `.felt/` index to query.
      Defaults to `default_felt_store/0`. The Poller threads its
      configured `state.felt_store` here so each shuttle instance reads
      from the felt store it's responsible for.
  """
  @spec render_prompt(String.t(), keyword()) :: String.t()
  def render_prompt(fiber_id, opts \\ []) do
    header = """
    The orchestration system Shuttle dispatched you on this fiber. The constitution describes what "done" looks like; drive toward it across one or more sessions. The `shuttle` and `felt` skills carry the practice — activate them next.

    Fiber: #{fiber_id}
    """

    compose_prompt(header, fiber_id, opts)
  end

  @doc """
  Renders the prompt injected into a *resumed* worker session.

  Mirrors the fresh dispatch prompt's From User block so the resumed
  worker sees the same intent signal at the top of context. The framing
  paragraph is shorter — skills, conventions, and the constitution are
  already in the resumed transcript, so repeating them is noise.

  When the latest review-comment has an empty summary (the kanban writes
  one on every requeue/resume click to keep `resume_mode` aligned with
  user intent — see `render_user_message_block/2`), the From User block
  is suppressed and the worker just gets the framing sentence.

  Pass `felt_store:` to control which `.felt/` index is queried; defaults
  to `default_felt_store/0`.
  """
  @spec render_resume_prompt(String.t(), keyword()) :: String.t()
  def render_resume_prompt(fiber_id, opts \\ []) do
    header = """
    Shuttle resumed your previous session on this fiber. Skills and conventions are already loaded in your transcript from the original dispatch; pick up from the last clean checkpoint, or address the message below if one's there.

    Fiber: #{fiber_id}
    """

    compose_prompt(header, fiber_id, opts)
  end

  @doc """
  Reads the most recent `--kind review-comment` event for `fiber_id` and
  renders it as a "From User · <relative time>" block for inclusion in
  the dispatch prompt. Returns "" if there are no review-comment events
  or the latest one has an empty summary.

  Persistence semantics: the latest user message is shown to every
  worker until a newer one is filed. There is no "consumed" flag — the
  worker reads it alongside the editorial chain and decides whether
  it's been addressed already.

  Pass `felt_store:` to control which `.felt/` index is queried.
  """
  @spec render_user_message_block(String.t(), keyword()) :: String.t()
  def render_user_message_block(fiber_id, opts \\ []) do
    case query_history(fiber_id, ["--kind", "review-comment", "--last", "1", "--json"], opts) do
      [event | _] ->
        # felt stores `--summary` text under `payload.text`. Read that key;
        # `payload.summary` was a dispatcher-side misread, never written.
        summary = (get_in(event, ["payload", "text"]) || "") |> String.trim()

        # Suppress the block for empty-text events. The kanban may write
        # a review-comment carrying only `resume_mode` (no user message)
        # to keep the latest `resume_mode` current; those events should
        # not render a From User block.
        if summary == "" do
          ""
        else
          when_iso = Map.get(event, "occurred_at", "")
          render_block("From User", relative_time(when_iso), summary)
        end

      _ ->
        ""
    end
  end

  @doc """
  Reads the most recent `--kind review-comment` event for `fiber_id` and
  returns a prelude block instructing the worker to stay alive after its
  initial task — when `payload.interactive == "true"`. Otherwise returns "".

  The kanban's modal sets `interactive=true` when the user wants to
  attach to the worker mid-conversation. The prelude overrides any
  `kill $PPID` instruction in the constitution: the worker completes
  the initial task, then waits for the human to take over.

  Pass `felt_store:` to control which `.felt/` index is queried.
  """
  @spec render_interactive_prelude(String.t(), keyword()) :: String.t()
  def render_interactive_prelude(fiber_id, opts \\ []) do
    case query_history(fiber_id, ["--kind", "review-comment", "--last", "1", "--json"], opts) do
      [event | _] ->
        if interactive_flag?(get_in(event, ["payload", "interactive"])) do
          render_block(
            "Interactive Mode",
            nil,
            "A human will attach to this session shortly. Complete the initial task as the constitution describes, but do NOT exit via `kill $PPID` afterward — leave the agent alive at a clean checkpoint and wait for the human's next message."
          )
        else
          ""
        end

      _ ->
        ""
    end
  end

  # felt's `--field key=value` stores the value as a string. Treat the
  # string "true" (and the boolean true, just in case) as truthy.
  defp interactive_flag?(true), do: true
  defp interactive_flag?("true"), do: true
  defp interactive_flag?(_), do: false

  # Render a labeled rule-bordered block. Header is "┌─ <label>[ · <time>] ─…",
  # content is indented two spaces, closed with a matching bottom rule.
  # Total visual width is fixed at @rule_width chars so blocks align in the
  # terminal even when their headers differ in length.
  @rule_width 76
  defp render_block(label, time_suffix, content) do
    header_text =
      case time_suffix do
        nil -> label
        "" -> label
        t -> "#{label} · #{t}"
      end

    # "┌─ " (3) + header_text + " " (1) + trailing dashes = @rule_width
    leading = "┌─ #{header_text} "
    trailing = max(@rule_width - String.length(leading), 3)
    top = leading <> String.duplicate("─", trailing)
    bottom = "└" <> String.duplicate("─", @rule_width - 1)

    body = indent_block(content, "  ")

    "#{top}\n#{body}\n#{bottom}"
  end

  # Convert ISO 8601 timestamp to a relative-time phrase ("just now",
  # "5 minutes ago", "2 days ago"). Granularity tops out at coarse units
  # — we want the worker to feel the gap ("picked back up after 2 days"),
  # not the precision. Falls back to the raw string on parse failure.
  defp relative_time(""), do: ""

  defp relative_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} ->
        DateTime.utc_now()
        |> DateTime.diff(dt)
        |> max(0)
        |> format_relative()

      _ ->
        iso
    end
  end

  defp relative_time(_), do: ""

  defp format_relative(s) when s < 60, do: "just now"
  defp format_relative(s) when s < 3600, do: pluralize(div(s, 60), "minute")
  defp format_relative(s) when s < 86_400, do: pluralize(div(s, 3600), "hour")
  defp format_relative(s) when s < 2_592_000, do: pluralize(div(s, 86_400), "day")
  defp format_relative(s) when s < 31_536_000, do: pluralize(div(s, 2_592_000), "month")
  defp format_relative(s), do: pluralize(div(s, 31_536_000), "year")

  defp pluralize(1, unit), do: "1 #{unit} ago"
  defp pluralize(n, unit), do: "#{n} #{unit}s ago"

  # Shared `felt history` JSON query with graceful fallback to []. Used by
  # both the directive block (filters on --kind review-comment) and the
  # handoff block (default editorial filter). `felt_store:` opt selects the
  # `.felt/` index to query — defaults to `default_felt_store/0` so callers
  # without a configured host (e.g. CLI smoke tests) still work.
  defp query_history(fiber_id, extra_args, opts) do
    felt_store = Keyword.get(opts, :felt_store, default_felt_store())
    args = ["-C", felt_store, "history", fiber_id] ++ extra_args

    case System.cmd("felt", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, events} when is_list(events) -> events
          _ -> []
        end

      _ ->
        []
    end
  end

  defp latest_history_session_id(fiber_id, opts) do
    fiber_id
    |> query_history(["--last", "20", "--json"], opts)
    |> Enum.find_value(fn event ->
      event
      |> get_in(["payload", "text"])
      |> extract_session_id()
    end)
  end

  defp extract_session_id(text) when is_binary(text) do
    case Regex.run(~r/(?:^|\s)session=([A-Za-z0-9._:-]+)/, text) do
      [_, "<unknown>"] -> nil
      [_, session_id] -> session_id
      _ -> nil
    end
  end

  defp extract_session_id(_), do: nil

  # Indent every line of `text` by `prefix`. Used to inset event summaries
  # under the box header so multi-line directives stay visually grouped.
  defp indent_block(text, prefix) do
    text
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&(prefix <> &1))
    |> Enum.join("\n")
  end

  @doc """
  Renders a standing-role run prompt for one scheduled occurrence.

  Mirrors the fresh dispatch prompt's shape (orientation paragraph +
  optional From User block). Standing roles are recurring fibers — this
  framing makes the run feel like one due occurrence of a durable
  responsibility rather than a new constitution. The awaiting-review
  handoff specifics (frontmatter shape on exit) live in the shuttle
  skill's "Standing Roles" section, not the prompt — keeping the prompt
  oriented and the practice in one place.
  """
  @spec render_standing_run_prompt(String.t(), String.t(), keyword()) :: String.t()
  def render_standing_run_prompt(fiber_id, run_id, opts \\ []) do
    ad_hoc? = Keyword.get(opts, :ad_hoc, false)

    orientation =
      if ad_hoc? do
        "The orchestration system Shuttle dispatched you for an ad-hoc run of this standing role. Standing roles are recurring responsibilities; this dispatch is right-now work and must not consume or advance the scheduled occurrence. On completion, set review.state to awaiting with this ad-hoc run id and preserve next_due_at. The `shuttle` and `felt` skills carry the practice — activate them next."
      else
        "The orchestration system Shuttle dispatched you for a scheduled run of this standing role. Standing roles are recurring responsibilities — this dispatch is one due occurrence, not a new fiber. The `shuttle` and `felt` skills carry the practice — activate them next; the skill's \"Standing Roles\" section covers the awaiting-review handoff at run completion."
      end

    header = """
    #{orientation}
    Fiber: #{fiber_id}
    Run:   #{run_id}
    """

    compose_prompt(header, fiber_id, opts)
  end

  # Shared composition for all top-level prompts: a per-prompt orientation
  # header plus the optional From User block. The shape is documented in
  # CLAUDE.md under "Dispatch prompt structure". Outcome and last-session
  # are deliberately not inlined — the shuttle skill prescribes that the
  # worker reads them via `felt show` / `felt history` on arrival, and
  # duplicating either here risks drift between the prompt's snapshot and
  # felt's view.
  defp compose_prompt(header, fiber_id, opts) do
    felt_opts = [felt_store: Keyword.get(opts, :felt_store, default_felt_store())]

    # Order: header, interactive prelude (when set), user message block.
    # The prelude sits before the From User block so the worker reads
    # the "stay alive" instruction before parsing the directive itself.
    [
      String.trim(header),
      render_interactive_prelude(fiber_id, felt_opts),
      render_user_message_block(fiber_id, felt_opts)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> String.trim()
  end

  @doc """
  tmux session name for a fiber ID.

  tmux on macOS and Linux accepts `/` in session names; preserving the
  literal fiber ID makes `tmux attach -t shuttle-<id>` work without
  transformation, and keeps the kanban's `listShuttleSessions` probe
  aligned with the Elixir Shuttle's naming.
  """
  @spec session_name(String.t()) :: String.t()
  def session_name(fiber_id) do
    "shuttle-" <> fiber_id
  end

  # ── Internal ──

  # First tries the runner's default cwd (so tests / one-off CLI invocations
  # in a project's working directory still resolve the fiber against that
  # project's `.felt/`). Falls back to the configured `felt_store` so the
  # daemon path always lands in the right index regardless of where the BEAM
  # process happens to be running. The default `felt_store` is
  # `default_felt_store/0` (~/loom) — pass `:felt_store` explicitly to point at
  # a different root.
  defp fetch_fiber(fiber_id, runner, opts) do
    felt_store = Keyword.get(opts, :felt_store, default_felt_store())

    case run_felt(runner, ["show", fiber_id, "--json"]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, fiber} -> {:ok, fiber}
          {:error, _} -> {:error, "invalid fiber JSON"}
        end

      {:error, _} ->
        case run_felt(runner, ["show", fiber_id, "--json"], cd: felt_store) do
          {:ok, output} ->
            case Jason.decode(output) do
              {:ok, fiber} -> {:ok, fiber}
              {:error, _} -> {:error, "invalid fiber JSON"}
            end

          {:error, _} ->
            {:error, :not_found}
        end
    end
  end

  defp check_not_closed(fiber) do
    status = Map.get(fiber, "status", "")

    if status == "closed" do
      {:error, :closed}
    else
      :ok
    end
  end

  defp check_not_running(fiber_id, runner) do
    session = session_name(fiber_id)

    case runner.cmd("tmux", ["has-session", "-t", session], stderr_to_stdout: true) do
      {_, 0} -> {:error, :already_running}
      {_, _} -> :ok
    end
  end

  defp resolve_agent(fiber) do
    # Prefer the post-migration shuttle.agent field when present; fall back
    # to legacy tag-based resolution (agent:<name> compound + bare aliases).
    # `felt show --json` rounds-trip-the-bytes (felt v1.0.4+): tool-owned
    # frontmatter namespaces like `shuttle:` and `tags:` appear as flat
    # top-level JSON keys.
    case get_in(fiber, ["shuttle", "agent"]) do
      name when is_binary(name) and name != "" ->
        Agents.resolve_by_name(name)

      _ ->
        tags = Map.get(fiber, "tags", [])
        Agents.resolve(tags)
    end
  end

  defp validate_agent(agent) do
    if agent.requires_model and is_nil(agent.model) do
      {:error, "agent #{agent.id} requires a model but none configured"}
    else
      :ok
    end
  end

  # Dispatch: fresh worker (new session) or resume previous.
  # `resume_intent` is `:fresh | {:previous, session_id}` from check_resume_intent/3.
  defp create_tmux_session(fiber_id, agent, work_dir, runner, prompt_context, resume_intent, opts) do
    session = session_name(fiber_id)
    felt_store = Keyword.get(opts, :felt_store, default_felt_store())

    case resume_intent do
      {:previous, session_id} ->
        # Resume mode: invoke the harness-appropriate resume command and
        # inject a small prompt as the next user turn so the resumed
        # worker knows it was deliberately woken (and sees the user's
        # latest directive if there is one). Without this the worker
        # would wake blind to the directive that triggered the resume.
        Logger.info(
          "Resuming #{fiber_id} session #{session_id} via #{agent.id} → tmux #{session}"
        )

        resume_prompt = render_resume_prompt(fiber_id, opts)
        command = Agents.build_resume_command(agent, session_id, resume_prompt)

        # claude --resume shows an interactive "you're about to use a
        # previous session" warning that only an Enter keypress at the
        # TTY can dismiss. The heredoc-piped prompt arrives *after* the
        # warning, so we can't fold it in. Schedule a tmux send-keys to
        # fire a couple seconds in. Other harnesses (codex/pi) don't
        # show this warning.
        run_script =
          build_run_script(fiber_id, command, agent.id,
            dismiss_resume_warning: agent.cli == "claude",
            session: session
          )

        spawn_tmux(session, work_dir, run_script, runner)

      :fresh ->
        # Fresh mode: build the full dispatch prompt.
        {command, session_uuid} = build_fresh_command(agent, fiber_id, prompt_context, opts)
        Logger.info("Dispatching #{fiber_id} via #{agent.id} → tmux session #{session}")
        run_script = build_run_script(fiber_id, command, agent.id)

        case spawn_tmux(session, work_dir, run_script, runner) do
          {:ok, _} = result ->
            # Store the session UUID so "Resume previous" is available next time.
            store_session_id(fiber_id, agent.id, session_uuid, runner, felt_store)
            result

          error ->
            error
        end
    end
  end

  # Build the fresh dispatch command. For Claude we generate and inject a UUID
  # upfront (--session-id) so we can store it synchronously. For codex/pi we
  # dispatch normally and capture the UUID asynchronously after spawn.
  defp build_fresh_command(agent, fiber_id, prompt_context, opts) do
    prompt = render_context_prompt(fiber_id, prompt_context, opts)

    case agent.cli do
      "claude" ->
        uuid = generate_uuid4()
        command = Agents.build_command(agent, prompt, session_id: uuid)
        {command, {:claude, uuid}}

      cli when cli in ["codex", "pi"] ->
        command = Agents.build_command(agent, prompt)
        work_dir = Keyword.get(opts, :work_dir, File.cwd!())
        {command, {:capture, cli, work_dir}}

      _ ->
        command = Agents.build_command(agent, prompt)
        {command, :none}
    end
  end

  # Spawn a tmux session from a run-script string.
  defp spawn_tmux(session, work_dir, run_script, runner) do
    tmp_path =
      Path.join(System.tmp_dir!(), "shuttle-run-#{System.unique_integer([:positive])}.sh")

    File.write!(tmp_path, run_script)
    File.chmod!(tmp_path, 0o755)

    args = ["new-session", "-d", "-s", session, "-c", work_dir, "bash", "-l", tmp_path]

    case runner.cmd("tmux", args, stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("Worker running: tmux attach -t #{session}")
        {:ok, session}

      {output, _} ->
        File.rm(tmp_path)
        {:error, "tmux failed: #{output}"}
    end
  end

  # Store the session UUID after a successful fresh dispatch.
  # - Claude: UUID was pre-specified; write synchronously.
  # - Codex/Pi: capture UUID from session file asynchronously with backoff.
  # - None: agent doesn't support session IDs; skip.
  defp store_session_id(fiber_id, agent_id, {:claude, uuid}, _runner, felt_store) do
    # Fire-and-forget: storing the UUID is best-effort; blocking dispatch on a
    # shuttle-ctl call would delay WorkerWatcher startup and cause flaky tests
    # (the watcher init checks the session, but the session can be removed by
    # other actors while we wait for shuttle-ctl to finish).
    Task.start(fn ->
      case System.cmd(
             "shuttle-ctl",
             ["--host", felt_store, "session-set", fiber_id, uuid, "--agent", agent_id],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          Logger.info("Stored session UUID #{uuid} for #{fiber_id}")

        {output, code} ->
          Logger.warning(
            "Could not store session UUID for #{fiber_id}: exit #{code}: #{String.trim(output)}"
          )
      end
    end)
  end

  defp store_session_id(fiber_id, agent_id, {:capture, cli, work_dir}, _runner, felt_store) do
    # Fire-and-forget: capture the session UUID from the harness's JSONL file
    # in a background task. The race window (50 ms × 20 attempts = ~1 s) is
    # short enough that the kanban card will show "Resume previous" by the
    # next manual refresh.
    Task.start(fn ->
      case capture_session_uuid(cli, work_dir, 20) do
        {:ok, uuid} ->
          case System.cmd(
                 "shuttle-ctl",
                 ["--host", felt_store, "session-set", fiber_id, uuid, "--agent", agent_id],
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              Logger.info("Captured and stored session UUID #{uuid} for #{fiber_id}")

            {output, code} ->
              Logger.warning(
                "Captured UUID #{uuid} but could not store for #{fiber_id}: " <>
                  "exit #{code}: #{String.trim(output)}"
              )
          end

        {:error, reason} ->
          Logger.warning(
            "Could not capture session UUID for #{fiber_id} (#{cli}): #{reason}. " <>
              "Resume previous will be unavailable."
          )
      end
    end)
  end

  defp store_session_id(_fiber_id, _agent_id, :none, _runner, _felt_store), do: :ok

  # Poll for the session UUID written by codex/pi to their respective session
  # JSONL files. Tries `attempts` times with 50 ms between each.
  #
  # Disk layouts:
  #   codex: ~/.codex/sessions/YYYY/MM/DD/rollout-<iso>-<uuid>.jsonl
  #          First line: {"type":"session_meta","payload":{"id":"<uuid>","cwd":"..."}}
  #   pi:    ~/.pi/agent/sessions/<encoded-cwd>/<iso>_<uuid>.jsonl
  #          First line: {"type":"session","id":"<uuid>","cwd":"..."}
  #
  # Both harnesses use UUIDv7 filenames (lexicographically = chronologically
  # ordered), so sorting names and taking the last gives the freshest session.
  defp capture_session_uuid(_cli, _work_dir, 0) do
    {:error, "timed out waiting for session file"}
  end

  defp capture_session_uuid(cli, work_dir, attempts) do
    :timer.sleep(50)

    case find_session_file(cli, work_dir) do
      {:ok, path} ->
        read_uuid_from_jsonl(cli, path, work_dir)

      {:error, _} ->
        capture_session_uuid(cli, work_dir, attempts - 1)
    end
  end

  defp find_session_file("codex", _work_dir) do
    home = System.user_home!()
    date = Date.utc_today()

    dir =
      Path.join([home, ".codex", "sessions", "#{date.year}", pad2(date.month), pad2(date.day)])

    case File.ls(dir) do
      {:ok, files} ->
        rollout_files = Enum.filter(files, &String.starts_with?(&1, "rollout-"))

        case Enum.sort(rollout_files) |> List.last() do
          nil -> {:error, :not_found}
          file -> {:ok, Path.join(dir, file)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_session_file("pi", work_dir) do
    home = System.user_home!()
    # Pi's encoded-cwd: absolute path with "/" replaced by "-", bracketed by "--".
    # e.g. /home/user/loom → --home-user-loom--
    encoded = "--" <> String.replace(work_dir, "/", "-") <> "--"
    dir = Path.join([home, ".pi", "agent", "sessions", encoded])

    case File.ls(dir) do
      {:ok, files} ->
        sorted = Enum.sort(files)

        case List.last(sorted) do
          nil -> {:error, :not_found}
          file -> {:ok, Path.join(dir, file)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_session_file(_cli, _work_dir), do: {:error, :unsupported}

  defp read_uuid_from_jsonl("codex", path, work_dir) do
    with {:ok, content} <- File.read(path),
         first_line <- content |> String.split("\n") |> List.first(""),
         {:ok, event} <- Jason.decode(first_line),
         "session_meta" <- Map.get(event, "type"),
         payload when is_map(payload) <- Map.get(event, "payload"),
         uuid when is_binary(uuid) and uuid != "" <- Map.get(payload, "id"),
         cwd when is_binary(cwd) <- Map.get(payload, "cwd") do
      # Verify the session belongs to this worker's working directory.
      if Path.expand(cwd) == Path.expand(work_dir) do
        {:ok, uuid}
      else
        {:error, "session cwd mismatch: #{cwd} ≠ #{work_dir}"}
      end
    else
      _ -> {:error, "could not parse session UUID from #{path}"}
    end
  end

  defp read_uuid_from_jsonl("pi", path, work_dir) do
    with {:ok, content} <- File.read(path),
         first_line <- content |> String.split("\n") |> List.first(""),
         {:ok, event} <- Jason.decode(first_line),
         "session" <- Map.get(event, "type"),
         uuid when is_binary(uuid) and uuid != "" <- Map.get(event, "id"),
         cwd when is_binary(cwd) <- Map.get(event, "cwd") do
      if Path.expand(cwd) == Path.expand(work_dir) do
        {:ok, uuid}
      else
        {:error, "session cwd mismatch: #{cwd} ≠ #{work_dir}"}
      end
    else
      _ -> {:error, "could not parse session UUID from #{path}"}
    end
  end

  defp read_uuid_from_jsonl(_cli, path, _work_dir),
    do: {:error, "unsupported harness for #{path}"}

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"

  # Generates a random UUID v4 using Erlang's :crypto module.
  # Sets version bits (byte 6 top nibble = 0100) and variant bits
  # (byte 8 top 2 bits = 10) per RFC 4122.
  defp generate_uuid4 do
    <<b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15>> =
      :crypto.strong_rand_bytes(16)

    v6 = (b6 &&& 0x0F) ||| 0x40
    v8 = (b8 &&& 0x3F) ||| 0x80

    :io_lib.format(
      "~2.16.0b~2.16.0b~2.16.0b~2.16.0b-~2.16.0b~2.16.0b-~2.16.0b~2.16.0b-~2.16.0b~2.16.0b-~2.16.0b~2.16.0b~2.16.0b~2.16.0b~2.16.0b~2.16.0b",
      [b0, b1, b2, b3, b4, b5, v6, b7, v8, b9, b10, b11, b12, b13, b14, b15]
    )
    |> IO.chardata_to_string()
  end

  defp render_context_prompt(fiber_id, {:standing_run, run_id}, opts) do
    render_standing_run_prompt(fiber_id, run_id, opts)
  end

  defp render_context_prompt(fiber_id, {:standing_run, run_id, :ad_hoc}, opts) do
    render_standing_run_prompt(fiber_id, run_id, Keyword.put(opts, :ad_hoc, true))
  end

  defp render_context_prompt(fiber_id, _, opts), do: render_prompt(fiber_id, opts)

  @doc false
  # Public for tests. Builds the bash script that wraps the harness command
  # with start/exit banners. With `dismiss_resume_warning: true` and a
  # `session:` name, also schedules a backgrounded tmux send-keys to
  # dismiss claude --resume's interactive warning page.
  def build_run_script(fiber_id, command, agent_id, opts \\ []) do
    dismiss_resume_warning = Keyword.get(opts, :dismiss_resume_warning, false)
    session = Keyword.get(opts, :session, "")

    # When resuming claude, schedule a backgrounded tmux send-keys to
    # dismiss the interactive warning page. Runs *inside* the same tmux
    # session it's targeting — tmux send-keys can target the current
    # session, the keypress lands on whatever's at the prompt (claude's
    # warning UI). 2 seconds is a safety margin for claude startup.
    dismiss_block =
      if dismiss_resume_warning and session != "" do
        # Single-quote the session name so slashes/dots don't trip the shell.
        ~s|( sleep 2; tmux send-keys -t '#{session}' Enter ) &\n    |
      else
        ""
      end

    """
    #!/bin/bash
    set -e
    trap 'rm -f "$0"' EXIT

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Shuttle worker — #{fiber_id} — agent=#{agent_id} — $(date '+%H:%M:%S')"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    #{dismiss_block}#{command}

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Shuttle worker exited (agent=#{agent_id})"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    """
  end

  defp run_felt(runner, args, opts \\ []) do
    cd = Keyword.get(opts, :cd)

    cmd_opts =
      if cd do
        [cd: cd, stderr_to_stdout: true]
      else
        [stderr_to_stdout: true]
      end

    case runner.cmd("felt", args, cmd_opts) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end
end
