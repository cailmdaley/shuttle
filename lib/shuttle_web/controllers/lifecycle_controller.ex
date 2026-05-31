defmodule ShuttleWeb.LifecycleController do
  @moduledoc """
  Agent-API endpoint for daemon-local shuttle lifecycle mutations.

  Cross-host lifecycle requests from Portolan land here on the selected
  daemon. The endpoint delegates to the existing shuttle-ctl Go CLI, so the
  validated offline frontmatter writer remains the single implementation of
  install/pause/resume/repeat/accept/set-model/set-interactive/uninstall.
  """

  use Phoenix.Controller, formats: [:json]

  alias Shuttle.FeltStores

  @allowed ~w(install pause resume repeat accept set-model set-interactive uninstall)

  def create(conn, params) do
    with {:ok, action} <- action(params),
         {:ok, args} <- args_for(action, params),
         {:ok, output} <- run(args) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, output)
    else
      {:error, reason} when is_binary(reason) ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, reason)

      {:command_error, status, output} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(422, "shuttle exited #{status}: #{output}")
    end
  end

  defp action(%{"action" => action}) when action in @allowed, do: {:ok, action}
  defp action(%{"action" => action}), do: {:error, "unknown lifecycle action #{inspect(action)}"}
  defp action(_), do: {:error, "missing lifecycle action"}

  defp args_for("install", %{"fiber" => fiber} = params) do
    args = ["install", fiber]
    args = add_string_flag(args, "--model", params["model"])
    args = add_string_flag(args, "--project-dir", params["project_dir"])
    args = add_bool_flag(args, "--disabled", params["disabled"])
    args = add_bool_flag(args, "--interactive", params["interactive"])
    {:ok, args}
  end

  defp args_for("pause", %{"fiber" => fiber} = params) do
    {:ok, ["pause", fiber] |> add_bool_flag("--no-kill", params["no_kill"])}
  end

  defp args_for("resume", %{"fiber" => fiber}), do: {:ok, ["resume", fiber]}

  defp args_for("repeat", %{"fiber" => fiber, "schedule" => schedule} = params) do
    {:ok,
     ["repeat", fiber, "--schedule", schedule, "--tz", Map.get(params, "tz", "UTC")]
     |> add_string_flag("--model", params["model"])
     |> add_string_flag("--project-dir", params["project_dir"])}
  end

  defp args_for("accept", %{"fiber" => fiber} = params) do
    {:ok, ["accept", fiber] |> add_bool_flag("--keep-outcome", params["keep_outcome"])}
  end

  defp args_for("set-model", %{"fiber" => fiber, "agent" => agent}),
    do: {:ok, ["set-model", fiber, agent]}

  defp args_for("set-interactive", %{"fiber" => fiber, "interactive" => interactive})
       when is_boolean(interactive) do
    with {:ok, host} <- host_for_fiber(fiber) do
      {:ok, ["--felt-store", host, "set-interactive", fiber, to_string(interactive)]}
    end
  end

  defp args_for("uninstall", %{"fiber" => fiber}), do: {:ok, ["uninstall", fiber]}
  defp args_for(action, _), do: {:error, "missing required fields for #{action}"}

  defp add_string_flag(args, _flag, nil), do: args
  defp add_string_flag(args, _flag, ""), do: args
  defp add_string_flag(args, flag, value), do: args ++ [flag, value]

  defp add_bool_flag(args, flag, true), do: args ++ [flag]
  defp add_bool_flag(args, _flag, _), do: args

  defp run(args) do
    case System.cmd("shuttle-ctl", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:command_error, status, output}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  defp host_for_fiber(fiber_id) do
    FeltStores.configured_hosts()
    |> Enum.find(&fiber_exists?(&1, fiber_id))
    |> case do
      nil -> {:error, "fiber not found: #{fiber_id}"}
      host -> {:ok, host}
    end
  end

  defp fiber_exists?(host, fiber_id) do
    case exact_fiber_path(host, fiber_id) do
      {:ok, _path} -> true
      {:error, _} -> false
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
end
