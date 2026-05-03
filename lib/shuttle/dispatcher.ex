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
  """
  @spec dispatch(String.t(), keyword()) :: dispatch_result()
  def dispatch(fiber_id, opts \\ []) do
    runner = Keyword.get(opts, :runner, Shuttle.Runner.Default)
    work_dir = Keyword.get(opts, :work_dir, File.cwd!())
    prompt_context = Keyword.get(opts, :prompt_context, :constitution)

    with {:ok, fiber} <- fetch_fiber(fiber_id, runner),
         :ok <- check_not_closed(fiber),
         :ok <- check_not_running(fiber_id, runner),
         {:ok, agent} <- resolve_agent(fiber),
         :ok <- validate_agent(agent),
         {:ok, session} <- create_tmux_session(fiber_id, agent, work_dir, runner, prompt_context) do
      {:ok, session}
    end
  end

  @doc """
  Renders the universal dispatch prompt for a fiber ID.

  Reads pending (unconsumed) review-comment events from felt history and
  prepends them to the prompt so the worker sees Cail's directives before
  the constitution body. The worker is responsible for incorporating each
  directive and calling `felt history mark-consumed` after.
  """
  @spec render_prompt(String.t()) :: String.t()
  def render_prompt(fiber_id) do
    review_block = render_pending_review_comments(fiber_id)

    base = """
    Shuttle dispatch. Fiber ID: #{fiber_id}

    You are a Shuttle-dispatched worker on this fiber.

    Activate the shuttle and felt skills before anything else, then follow them.

    Read the constitution fresh via `felt show #{fiber_id}`. The work may take one session or many — Shuttle redispatches a fresh worker on the next poll, and `felt history #{fiber_id} --last 1` lands them warm. **Exit before context is half-full.** Auto-compact mid-thought hands the next worker a degraded summary, and the editorial event you'd write afterward gets composed from that degraded view rather than full attention. A clean break at the next sub-task boundary, well before half, is a stronger handoff than pushing through. End this session with `kill $PPID` at a clean break, when you're blocked, or when the constitution is realized.

    Update the constitution's `outcome:` to reflect where the work now stands, and append an editorial event with `felt history append #{fiber_id} --summary "…"` as the handoff for the next worker; file crystallizations as sub-fibers; commit. Status `closed` signals the constitution is realized; `tempered: true` is human-only.
    """

    (review_block <> base)
    |> String.trim()
  end

  @doc """
  Reads pending (unconsumed) review-comment events for `fiber_id` and renders
  a directive block for inclusion at the top of the dispatch prompt.

  Returns an empty string when there are no pending review comments, so
  callers can concatenate unconditionally. On failure (felt not available,
  no history yet) falls back to empty string — dispatch continues without
  the review block rather than failing.

  Workers are expected to:
    1. Read the directive shown here.
    2. Incorporate it into the work.
    3. Call `felt history mark-consumed #{fiber_id} --rowid <N>` for each event.
  """
  @spec render_pending_review_comments(String.t()) :: String.t()
  def render_pending_review_comments(fiber_id) do
    loom = System.user_home() <> "/loom"

    case System.cmd(
           "felt",
           [
             "-C",
             loom,
             "history",
             fiber_id,
             "--kind",
             "review-comment",
             "--unconsumed",
             "--json"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, events} when is_list(events) and length(events) > 0 ->
            directives =
              events
              |> Enum.map(fn e ->
                rowid = Map.get(e, "rowid", "?")
                actor = Map.get(e, "actor", "")
                summary = get_in(e, ["payload", "summary"]) || ""
                "  [rowid=#{rowid} from #{actor}]\n  #{String.replace(summary, "\n", "\n  ")}"
              end)
              |> Enum.join("\n\n")

            """
            ┌─ Pending review directive(s) from Cail ─────────────────────────────────
            #{directives}

            Incorporate the directive(s) above into the constitution/work, then mark
            each consumed via:
              felt history mark-consumed #{fiber_id} --rowid <N>
            └──────────────────────────────────────────────────────────────────────────

            """

          _ ->
            ""
        end

      _ ->
        ""
    end
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

  defp fetch_fiber(fiber_id, runner) do
    case run_felt(runner, ["show", fiber_id, "--json"]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, fiber} -> {:ok, fiber}
          {:error, _} -> {:error, "invalid fiber JSON"}
        end

      {:error, _} ->
        # Try ~/loom as fallback
        loom = System.user_home() <> "/loom"

        case run_felt(runner, ["show", fiber_id, "--json"], cd: loom) do
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

  defp create_tmux_session(fiber_id, agent, work_dir, runner, prompt_context) do
    session = session_name(fiber_id)
    prompt = render_context_prompt(fiber_id, prompt_context)
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

  defp render_context_prompt(fiber_id, {:standing_run, run_id}) do
    render_standing_run_prompt(fiber_id, run_id)
  end

  defp render_context_prompt(fiber_id, _), do: render_prompt(fiber_id)

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
