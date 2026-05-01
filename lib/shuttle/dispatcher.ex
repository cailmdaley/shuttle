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

    with {:ok, fiber} <- fetch_fiber(fiber_id, runner),
         :ok <- check_not_closed(fiber),
         :ok <- check_not_running(fiber_id, runner),
         {:ok, agent} <- resolve_agent(fiber),
         :ok <- validate_agent(agent),
         {:ok, session} <- create_tmux_session(fiber_id, agent, work_dir, runner) do
      {:ok, session}
    end
  end

  @doc """
  Renders the universal dispatch prompt for a fiber ID.
  """
  @spec render_prompt(String.t()) :: String.t()
  def render_prompt(fiber_id) do
    """
    Shuttle dispatch. Fiber ID: #{fiber_id}

    You are a Shuttle-dispatched worker on this fiber.

    Activate the shuttle and felt skills before anything else, then follow them.

    Read the constitution fresh via `felt show #{fiber_id}`. The work may take one session or many. End this session with `kill $PPID` when context fills, when you've reached a clean break, or when the constitution is realized.

    Update the constitution's `outcome:` to reflect where the work now stands, and append an editorial event with `felt history append #{fiber_id} --summary "…"` as the handoff for the next worker; file crystallizations as sub-fibers; commit. Status `closed` signals the constitution is realized; `tempered: true` is human-only.
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
    tags = Map.get(fiber, "tags", [])
    Agents.resolve(tags)
  end

  defp validate_agent(agent) do
    if agent.requires_model and is_nil(agent.model) do
      {:error, "agent #{agent.id} requires a model but none configured"}
    else
      :ok
    end
  end

  defp create_tmux_session(fiber_id, agent, work_dir, runner) do
    session = session_name(fiber_id)
    prompt = render_prompt(fiber_id)
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
