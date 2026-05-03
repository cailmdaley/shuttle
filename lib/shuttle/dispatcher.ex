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
         :ok <- validate_agent(agent),
         {:ok, session} <-
           create_tmux_session(fiber_id, agent, work_dir, runner, prompt_context,
             felt_host: felt_host
           ) do
      {:ok, session}
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
    # `felt show --json` returns the shuttle: block as a nested map keyed by
    # string in the fiber JSON.
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

  defp create_tmux_session(fiber_id, agent, work_dir, runner, prompt_context, opts) do
    session = session_name(fiber_id)
    prompt = render_context_prompt(fiber_id, prompt_context, opts)
    command = Agents.build_command(agent, prompt)

    # Build the run script — same shape as shuttle-worker.sh's RUN_SCRIPT
    run_script = build_run_script(fiber_id, command, agent.id)

    # Write run script to temp file
    tmp_path =
      Path.join(System.tmp_dir!(), "shuttle-run-#{System.unique_integer([:positive])}.sh")

    File.write!(tmp_path, run_script)
    File.chmod!(tmp_path, 0o755)

    args = [
      "new-session",
      "-d",
      "-s",
      session,
      "-c",
      work_dir,
      "bash",
      "-l",
      tmp_path
    ]

    Logger.info("Dispatching #{fiber_id} via #{agent.id} → tmux session #{session}")

    case runner.cmd("tmux", args, stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("Worker running: tmux attach -t #{session}")
        {:ok, session}

      {output, _} ->
        File.rm(tmp_path)
        {:error, "tmux failed: #{output}"}
    end
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
