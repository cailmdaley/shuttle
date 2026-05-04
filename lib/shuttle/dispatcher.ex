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
    * `:felt_host` — directory containing the `.felt/` index this dispatch
      should read fibers and history from. Defaults to `default_felt_host/0`.
      The Poller passes its configured `state.felt_host` here so each shuttle
      instance is consistent within itself; running multiple shuttle instances
      against different felt hosts (e.g. one for `~/loom`, another for a
      standalone project root) is the supported way to span felt hosts.
    * `:prompt_context` — `:constitution` (default) or `:standing_run`.
  """
  @spec dispatch(String.t(), keyword()) :: dispatch_result()
  def dispatch(fiber_id, opts \\ []) do
    runner = Keyword.get(opts, :runner, Shuttle.Runner.Default)
    work_dir = Keyword.get(opts, :work_dir, File.cwd!())
    prompt_context = Keyword.get(opts, :prompt_context, :constitution)
    felt_host = Keyword.get(opts, :felt_host, default_felt_host())

    with {:ok, fiber} <- fetch_fiber(fiber_id, runner, felt_host: felt_host),
         :ok <- check_not_closed(fiber),
         :ok <- check_not_running(fiber_id, runner),
         {:ok, agent} <- resolve_agent(fiber),
         :ok <- validate_agent(agent) do
      resume_intent = check_resume_intent(fiber_id, fiber, felt_host: felt_host)
      create_tmux_session(fiber_id, agent, work_dir, runner, prompt_context, resume_intent,
        felt_host: felt_host
      )
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
    felt_host = Keyword.get(opts, :felt_host, default_felt_host())

    case query_history(fiber_id, ["--kind", "review-comment", "--last", "1", "--json"],
           felt_host: felt_host
         ) do
      [event | _] ->
        resume_mode = get_in(event, ["payload", "resume_mode"])
        session_id = get_in(fiber, ["shuttle", "session", "id"])

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
  Returns shuttle's default felt host. Mirrors `Shuttle.Poller.default_felt_host/0`
  — kept locally so `Dispatcher` works standalone (e.g. via the CLI) without a
  running Poller.

  Resolution order:

    1. `$LOOM_HOME` if set (matches portolan's `resolveGlobalFiberId`, so
       both processes can be pointed at the same root by exporting one
       env var).
    2. `~/loom` as a final fallback (Cail's primary felt host).

  Projects that live outside the configured felt host should run their own
  shuttle instance with `felt_host:` pointing at the project root, rather
  than relying on the default.
  """
  @spec default_felt_host() :: String.t()
  def default_felt_host do
    case System.get_env("LOOM_HOME") do
      v when is_binary(v) and v != "" -> v
      _ -> System.user_home() <> "/loom"
    end
  end

  @doc """
  Renders the universal dispatch prompt for a fiber ID.

  Inlines two pieces of context directly into the prompt so the worker
  has them in context immediately, no tool calls required:

    - The most recent `review-comment` event (Cail's latest directive),
      if any. Persists across arbitrarily many worker handoffs — only
      replaced when Cail files a newer directive. The worker reads the
      directive *and* the editorial chain to decide whether it's still
      in play; we deliberately don't track "consumed" because it pushes
      a brittle ack-or-the-directive-is-lost burden onto the worker.
    - The most recent editorial event (the previous worker's handoff
      or this fiber's bootstrap), if any.

  Both sections are omitted when empty so the prompt stays clean for
  fresh fibers. On felt failure (binary missing, no history yet) we
  fall back to empty strings — dispatch continues rather than failing.

  ## Options

    * `:felt_host` — directory containing the `.felt/` index to query.
      Defaults to `default_felt_host/0`. The Poller threads its
      configured `state.felt_host` here so each shuttle instance
      reads from the felt host it's responsible for, rather than a
      hardcoded loom root.
  """
  @spec render_prompt(String.t(), keyword()) :: String.t()
  def render_prompt(fiber_id, opts \\ []) do
    felt_host = Keyword.get(opts, :felt_host, default_felt_host())
    directive_block = render_latest_review_directive(fiber_id, felt_host: felt_host)
    handoff_block = render_latest_editorial(fiber_id, felt_host: felt_host)

    base = """
    Shuttle dispatch. Fiber ID: #{fiber_id}

    You are a Shuttle-dispatched worker on this fiber.

    Activate the shuttle and felt skills before anything else, then follow them.

    Read the constitution fresh via `felt show #{fiber_id}`. The work may take one session or many — Shuttle redispatches a fresh worker on the next poll. **Exit before context is half-full.** Auto-compact mid-thought hands the next worker a degraded summary, and the editorial event you'd write afterward gets composed from that degraded view rather than full attention. A clean break at the next sub-task boundary, well before half, is a stronger handoff than pushing through. End this session with `kill $PPID` at a clean break, when you're blocked, or when the constitution is realized.

    Update the constitution's `outcome:` to reflect where the work now stands, and append an editorial event with `felt history append #{fiber_id} --summary "…"` as the handoff for the next worker; file crystallizations as sub-fibers; commit. Status `closed` signals the constitution is realized; `tempered: true` is human-only.
    """

    (directive_block <> handoff_block <> base)
    |> String.trim()
  end

  @doc """
  Reads the most recent `--kind review-comment` event for `fiber_id` and
  renders a directive block for inclusion at the top of the dispatch
  prompt. Returns "" if there are no review-comment events.

  Persistence semantics: the latest directive is shown to every worker
  until Cail files a newer one. There is no "consumed" flag — the worker
  sees both the directive and the editorial chain, and decides from the
  chain whether the directive has already been addressed.

  Pass `felt_host:` to control which `.felt/` index is queried.
  """
  @spec render_latest_review_directive(String.t(), keyword()) :: String.t()
  def render_latest_review_directive(fiber_id, opts \\ []) do
    case query_history(fiber_id, ["--kind", "review-comment", "--last", "1", "--json"], opts) do
      [event | _] ->
        actor = Map.get(event, "actor", "")
        when_iso = Map.get(event, "occurred_at", "")
        summary = get_in(event, ["payload", "summary"]) || ""

        """
        ┌─ Most recent directive from Cail (#{when_iso}, #{actor}) ──────────────────
        #{indent_block(summary, "  ")}

        Read this alongside the prior handoff below and the editorial chain
        (`felt history #{fiber_id}`). If the chain shows the directive has
        already been addressed in a previous loop, treat it as historical
        context; otherwise incorporate it into your work.
        └──────────────────────────────────────────────────────────────────────────

        """

      _ ->
        ""
    end
  end

  @doc """
  Reads the most recent editorial event for `fiber_id` and renders it as
  a "previous handoff" block. Returns "" if there are no editorial events.

  Inlining `--last 1` directly into the prompt removes the worker's tool
  call to fetch it — the previous handoff is in context the moment the
  worker wakes.

  Pass `felt_host:` to control which `.felt/` index is queried.
  """
  @spec render_latest_editorial(String.t(), keyword()) :: String.t()
  def render_latest_editorial(fiber_id, opts \\ []) do
    case query_history(fiber_id, ["--last", "1", "--json"], opts) do
      [event | _] ->
        actor = Map.get(event, "actor", "")
        when_iso = Map.get(event, "occurred_at", "")
        summary = get_in(event, ["payload", "summary"]) || ""

        """
        ┌─ Previous editorial handoff (#{when_iso}, #{actor}) ──────────────────────
        #{indent_block(summary, "  ")}
        └──────────────────────────────────────────────────────────────────────────

        """

      _ ->
        ""
    end
  end

  # Shared `felt history` JSON query with graceful fallback to []. Used by
  # both the directive block (filters on --kind review-comment) and the
  # handoff block (default editorial filter). `felt_host:` opt selects the
  # `.felt/` index to query — defaults to `default_felt_host/0` so callers
  # without a configured host (e.g. CLI smoke tests) still work.
  defp query_history(fiber_id, extra_args, opts) do
    felt_host = Keyword.get(opts, :felt_host, default_felt_host())
    args = ["-C", felt_host, "history", fiber_id] ++ extra_args

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
  """
  @spec render_standing_run_prompt(String.t(), String.t()) :: String.t()
  def render_standing_run_prompt(fiber_id, run_id) do
    """
    Shuttle standing-role run. Fiber ID: #{fiber_id}
    Run ID: #{run_id}

    You are a scheduled Shuttle worker for this standing role.

    Activate the shuttle and felt skills before anything else, then follow them.

    Read the role fresh via `felt show #{fiber_id}`. This is one due occurrence of the same durable responsibility, not a new fiber.

    Write the latest work product into the role fiber's `outcome:`. Append an editorial event with `felt history append #{fiber_id} --summary "Run #{run_id}: …"` that archives the run and includes stable decision handles for anything the user may ask you to revisit. File crystallizations as sub-fibers when they are durable.

    Before exiting, manually edit the role fiber's `shuttle:` frontmatter into the awaiting-review shape: `review.state: awaiting`, `review.run_id: #{run_id}`, `review.completed_at: <now>`, `review.accepted_run_id: null`, `next_due_at: null`, and `last_run_at: <now>`. Leave `status: active`.

    Recurrence resumes only after a human or agent manually accepts the reviewed run by editing `shuttle.review` to accepted/scheduled, setting `accepted_run_id` to this run id, and setting the next `next_due_at`. End this session with `kill $PPID` when the run is complete or at a clean break — exit before context is half-full, so the run summary is written from full attention rather than post-compact.
    """
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
  # project's `.felt/`). Falls back to the configured `felt_host` so the
  # daemon path always lands in the right index regardless of where the BEAM
  # process happens to be running. The default `felt_host` is
  # `default_felt_host/0` (~/loom) — pass `:felt_host` explicitly to point at
  # a different root.
  defp fetch_fiber(fiber_id, runner, opts) do
    felt_host = Keyword.get(opts, :felt_host, default_felt_host())

    with {:ok, base} <- felt_show_json(fiber_id, runner, felt_host) do
      # `felt show --json` does not include the `shuttle:` block or `tags:`
      # — its JSON output is restricted to id/name/status/created_at/body/
      # modified_at. The dispatcher consumes both (resolve_agent reads
      # shuttle.agent + tags; check_resume_intent reads shuttle.session.id),
      # so we enrich here via dedicated --field calls. See finding fiber:
      # ai-futures/shuttle/finding-dispatcher-felt-show-json-misses-shuttle-block.
      shuttle = fetch_shuttle_field(fiber_id, runner, felt_host)
      tags = fetch_tags_field(fiber_id, runner, felt_host)

      fiber =
        base
        |> maybe_put("shuttle", shuttle)
        |> maybe_put("tags", tags)

      {:ok, fiber}
    end
  end

  defp felt_show_json(fiber_id, runner, felt_host) do
    case run_felt(runner, ["show", fiber_id, "--json"]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, fiber} -> {:ok, fiber}
          {:error, _} -> {:error, "invalid fiber JSON"}
        end

      {:error, _} ->
        case run_felt(runner, ["show", fiber_id, "--json"], cd: felt_host) do
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

  # Reads the `shuttle:` frontmatter block via `felt show --field shuttle`,
  # which emits structured (map) values as YAML. Returns the parsed map, or
  # nil on absence/parse failure. Tries the explicit felt host on initial
  # failure (mirrors felt_show_json's dual-attempt shape).
  defp fetch_shuttle_field(fiber_id, runner, felt_host) do
    case run_felt(runner, ["show", fiber_id, "--field", "shuttle"]) do
      {:ok, output} ->
        parse_shuttle_yaml(output)

      {:error, _} ->
        case run_felt(runner, ["show", fiber_id, "--field", "shuttle"], cd: felt_host) do
          {:ok, output} -> parse_shuttle_yaml(output)
          {:error, _} -> nil
        end
    end
  end

  defp parse_shuttle_yaml(output) when is_binary(output) do
    trimmed = String.trim(output)

    if trimmed == "" do
      nil
    else
      case YamlElixir.read_from_string(trimmed) do
        {:ok, map} when is_map(map) -> map
        _ -> nil
      end
    end
  end

  # Reads the `tags:` frontmatter via `felt show --field tags`, which emits
  # sequences of scalars one-per-line (per `felt show --help`). Returns the
  # list, [] on absence.
  defp fetch_tags_field(fiber_id, runner, felt_host) do
    case run_felt(runner, ["show", fiber_id, "--field", "tags"]) do
      {:ok, output} ->
        parse_tags_lines(output)

      {:error, _} ->
        case run_felt(runner, ["show", fiber_id, "--field", "tags"], cd: felt_host) do
          {:ok, output} -> parse_tags_lines(output)
          {:error, _} -> []
        end
    end
  end

  defp parse_tags_lines(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
    # `fetch_fiber` enriches the JSON via `--field shuttle` and `--field
    # tags` calls, since `felt show --json` strips both fields.
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

    case resume_intent do
      {:previous, session_id} ->
        # Resume mode: invoke the harness-appropriate resume command.
        # No new prompt is passed — the worker picks up from its transcript.
        Logger.info(
          "Resuming #{fiber_id} session #{session_id} via #{agent.id} → tmux #{session}"
        )

        command = Agents.build_resume_command(agent, session_id)
        run_script = build_run_script(fiber_id, command, agent.id)
        spawn_tmux(session, work_dir, run_script, runner)

      :fresh ->
        # Fresh mode: build the full dispatch prompt.
        {command, session_uuid} = build_fresh_command(agent, fiber_id, prompt_context, opts)
        Logger.info("Dispatching #{fiber_id} via #{agent.id} → tmux session #{session}")
        run_script = build_run_script(fiber_id, command, agent.id)

        case spawn_tmux(session, work_dir, run_script, runner) do
          {:ok, _} = result ->
            # Store the session UUID so "Resume previous" is available next time.
            store_session_id(fiber_id, agent.id, session_uuid, runner)
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
  defp store_session_id(fiber_id, agent_id, {:claude, uuid}, _runner) do
    # Fire-and-forget: storing the UUID is best-effort; blocking dispatch on a
    # shuttle-ctl call would delay WorkerWatcher startup and cause flaky tests
    # (the watcher init checks the session, but the session can be removed by
    # other actors while we wait for shuttle-ctl to finish).
    Task.start(fn ->
      case System.cmd("shuttle-ctl", ["session-set", fiber_id, uuid, "--agent", agent_id],
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

  defp store_session_id(fiber_id, agent_id, {:capture, cli, work_dir}, _runner) do
    # Fire-and-forget: capture the session UUID from the harness's JSONL file
    # in a background task. The race window (50 ms × 20 attempts = ~1 s) is
    # short enough that the kanban card will show "Resume previous" by the
    # next manual refresh.
    Task.start(fn ->
      case capture_session_uuid(cli, work_dir, 20) do
        {:ok, uuid} ->
          case System.cmd("shuttle-ctl", ["session-set", fiber_id, uuid, "--agent", agent_id],
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

  defp store_session_id(_fiber_id, _agent_id, :none, _runner), do: :ok

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
    dir = Path.join([home, ".codex", "sessions", "#{date.year}", pad2(date.month), pad2(date.day)])

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
    # e.g. /Users/cd280747/loom → --Users-cd280747-loom--
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

  # The standing-run prompt currently doesn't read history, so it ignores
  # `felt_host`. Threaded through anyway for symmetry — if a future variant
  # wants to inline the prior run's editorial event, the plumbing is in place.
  defp render_context_prompt(fiber_id, {:standing_run, run_id}, _opts) do
    render_standing_run_prompt(fiber_id, run_id)
  end

  defp render_context_prompt(fiber_id, _, opts), do: render_prompt(fiber_id, opts)

  defp build_run_script(fiber_id, command, agent_id) do
    """
    #!/bin/bash
    set -e
    trap 'rm -f "$0"' EXIT

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Shuttle worker — #{fiber_id} — agent=#{agent_id} — $(date '+%H:%M:%S')"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    #{command}

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
