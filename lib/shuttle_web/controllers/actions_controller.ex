defmodule ShuttleWeb.ActionsController do
  @moduledoc """
  Shuttle-owned lifecycle action classification for external views.
  """

  use Phoenix.Controller, formats: [:json]

  alias Shuttle.{Actions, Dispatcher, FeltStores}

  def show(conn, %{"fiber_id" => parts}) do
    fiber_id = Path.join(parts)

    case actions_for(fiber_id) do
      {:ok, actions} ->
        json(conn, %{fiber_id: fiber_id, actions: actions})

      {:error, reason} ->
        conn |> put_status(404) |> json(%{fiber_id: fiber_id, error: render_error(reason)})
    end
  end

  def resolve(conn, %{"fiber_id" => fiber_id, "target" => target}) do
    case resolve_action(fiber_id, target) do
      {:ok, action} ->
        json(conn, %{fiber_id: fiber_id, target: target, action: action})

      {:error, :unknown_target} ->
        conn
        |> put_status(400)
        |> json(%{fiber_id: fiber_id, target: target, error: "unknown_target"})

      {:error, reason} ->
        conn
        |> put_status(404)
        |> json(%{fiber_id: fiber_id, target: target, error: render_error(reason)})
    end
  end

  def resolve(conn, _params) do
    conn |> put_status(400) |> json(%{error: "fiber_id and target are required"})
  end

  def invoke(conn, %{"fiber_id" => fiber_id, "action" => action}) do
    with :ok <- validate_action(action),
         {:ok, host} <- validate_available(fiber_id, action),
         :ok <- invoke_action(fiber_id, action, host) do
      json(conn, %{fiber_id: fiber_id, action: action, invoked: true})
    else
      {:error, :unknown_action} ->
        conn
        |> put_status(400)
        |> json(%{fiber_id: fiber_id, action: action, invoked: false, error: "unknown_action"})

      {:error, :action_not_available} ->
        conn
        |> put_status(409)
        |> json(%{
          fiber_id: fiber_id,
          action: action,
          invoked: false,
          error: "action_not_available"
        })

      {:error, {:command_error, status, output}} ->
        conn
        |> put_status(422)
        |> json(%{
          fiber_id: fiber_id,
          action: action,
          invoked: false,
          error: "shuttle exited #{status}: #{String.trim(output)}"
        })

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{
          fiber_id: fiber_id,
          action: action,
          invoked: false,
          error: render_error(reason)
        })
    end
  end

  def invoke(conn, _params) do
    conn |> put_status(400) |> json(%{error: "fiber_id and action are required"})
  end

  defp validate_action(action) do
    if Actions.known_action?(action), do: :ok, else: {:error, :unknown_action}
  end

  defp validate_available(fiber_id, action) do
    case actions_for(fiber_id) do
      {:ok, actions, host} ->
        if Enum.any?(actions, &(Map.get(&1, :id) == action || Map.get(&1, "id") == action)) do
          {:ok, host}
        else
          {:error, :action_not_available}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp actions_for(fiber_id) do
    with {:ok, fiber, host} <- fetch_fiber(fiber_id) do
      {:ok, Actions.actions_for(fiber, running?(fiber_id)), host}
    end
  end

  defp resolve_action(fiber_id, target) do
    with {:ok, fiber, _host} <- fetch_fiber(fiber_id) do
      Actions.resolve_transition(fiber, target, running?(fiber_id))
    end
  end

  # Returns {:ok, fiber, host} so callers can pass the right `--felt-store`
  # to shuttle-ctl. Without that flag, the CLI walks from its own PWD looking
  # for `.felt/` and hits a different store than the one the daemon resolved
  # the fiber from — typical symptom is "shuttle: fiber X has no shuttle:
  # block" for fibers whose canonical store is a project-scoped felt-store
  # symlinked into loom (e.g. lightcone).
  defp fetch_fiber(fiber_id) do
    FeltStores.configured_hosts()
    |> Enum.find_value(fn host ->
      with {:ok, path} <- exact_fiber_path(host, fiber_id),
           {:ok, fiber} <- read_fiber_frontmatter(path, fiber_id) do
        {:ok, fiber, host}
      else
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, :not_found}
      result -> result
    end
  end

  defp exact_fiber_path(host, fiber_id) do
    segments = String.split(fiber_id, "/")
    basename = List.last(segments)
    felt_dir = Path.join(host, ".felt")
    bare_path = Path.join(felt_dir, "#{basename}.md")
    dir_path = Path.join([felt_dir | segments] ++ ["#{basename}.md"])

    cond do
      not String.contains?(fiber_id, "/") and File.exists?(bare_path) -> {:ok, bare_path}
      File.exists?(dir_path) -> {:ok, dir_path}
      true -> {:error, :not_found}
    end
  end

  defp read_fiber_frontmatter(path, fiber_id) do
    with {:ok, text} <- File.read(path),
         {:ok, frontmatter} <- split_frontmatter(text),
         {:ok, fiber} <- YamlElixir.read_from_string(frontmatter) do
      {:ok, Map.put(fiber || %{}, "id", fiber_id)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_frontmatter}
    end
  end

  defp split_frontmatter("---\n" <> rest) do
    case :binary.split(rest, "\n---", [:global]) do
      [frontmatter, _body] -> {:ok, frontmatter}
      [frontmatter, _separator_tail | _] -> {:ok, frontmatter}
      _ -> {:error, :missing_frontmatter}
    end
  end

  defp split_frontmatter(_), do: {:error, :missing_frontmatter}

  defp running?(fiber_id) do
    case System.cmd("tmux", ["has-session", "-t", "=" <> Dispatcher.session_name(fiber_id)],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp invoke_action(fiber_id, "pause", host), do: run(["pause", fiber_id], host)
  defp invoke_action(fiber_id, "reopen", host), do: run(["reopen", fiber_id], host)
  defp invoke_action(fiber_id, "accept-run", host), do: run(["accept", fiber_id], host)
  defp invoke_action(fiber_id, "continue-run-fresh", host), do: run(["resume", fiber_id], host)
  defp invoke_action(fiber_id, "continue-run-previous", host), do: run(["resume", fiber_id], host)
  defp invoke_action(fiber_id, "close-awaiting-review", host), do: run(["close", fiber_id], host)

  defp invoke_action(fiber_id, "close-tempered", host),
    do: run(["close", fiber_id, "--tempered=true"], host)

  defp invoke_action(fiber_id, "close-composted", host),
    do: run(["close", fiber_id, "--tempered=false"], host)

  defp invoke_action(fiber_id, "dispatch-ad-hoc", _host) do
    case Shuttle.Poller.dispatch_fiber(Shuttle.Poller, fiber_id,
           force: true,
           ad_hoc: true
         ) do
      {:ok, _session} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Prepend `--felt-store <host>` so shuttle-ctl reads the same `.felt/` index
  # the daemon resolved the fiber against. Without this, shuttle-ctl falls
  # back to its own default discovery (PWD walk / config) which can land on a
  # different store and report bogus "no shuttle: block" errors for fibers
  # whose canonical store is project-scoped (e.g. lightcone).
  defp run(args, nil), do: run_cmd(args)
  defp run(args, host) when is_binary(host), do: run_cmd(["--felt-store", host | args])

  defp run_cmd(args) do
    case System.cmd("shuttle-ctl", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:command_error, status, output}}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  defp render_error(reason) when is_binary(reason), do: reason
  defp render_error(reason) when is_atom(reason), do: to_string(reason)
  defp render_error(reason), do: inspect(reason)
end
