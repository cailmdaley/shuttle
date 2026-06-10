defmodule ShuttleWeb.LifecycleController do
  @moduledoc """
  Agent-API endpoint for shuttle lifecycle mutations — the kanban's promote /
  requeue / pause / resume writes, posted directly to Shuttle.

  Owner-routed via `Shuttle.OriginRouter`: a local-owned card's mutation runs
  here; a remote-owned card's request is forwarded to the owning daemon's
  identical `/lifecycle` (origin stripped) and relayed verbatim. The local
  branch delegates to the existing shuttle-ctl Go CLI, so the validated offline
  frontmatter writer remains the single implementation of
  install/pause/resume/repeat/accept/set-model/set-outcome/uninstall.
  """

  use Phoenix.Controller, formats: [:json]

  alias Shuttle.{FeltStores, LifecycleService, OriginRouter}

  @allowed ~w(install pause resume repeat accept set-model set-outcome uninstall)

  def create(conn, params) do
    case OriginRouter.route(Map.get(params, "origin")) do
      {:remote, remote} ->
        relay_text(conn, OriginRouter.forward(remote, "/api/v1/lifecycle", conn.body_params))

      :local ->
        create_local(conn, params)
    end
  end

  defp create_local(conn, params) do
    with {:ok, action} <- action(params),
         {:ok, output} <- execute(action, params) do
      # Every lifecycle verb here mutates the fiber doc (status/outcome/model/
      # shuttle block). Re-read it into the document cache so the kanban's
      # post-action refetch reflects the change now, not after the next poll.
      refresh_card(params)

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

  defp relay_text(conn, {:forwarded, status, body}) do
    conn |> put_resp_content_type("text/plain") |> send_resp(status, body)
  end

  defp relay_text(conn, {:error, {:forward_failed, name, reason}}) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(502, "forward to #{name} failed: #{inspect(reason)}")
  end

  defp action(%{"action" => action}) when action in @allowed, do: {:ok, action}
  defp action(%{"action" => action}), do: {:error, "unknown lifecycle action #{inspect(action)}"}
  defp action(_), do: {:error, "missing lifecycle action"}

  defp execute("accept", %{"fiber" => fiber} = params) do
    with {:ok, fiber_id} <- fiber_address(fiber) do
      LifecycleService.accept(fiber_id, keep_outcome: truthy?(params["keep_outcome"]))
    end
  end

  defp execute("resume", %{"fiber" => fiber}) do
    with {:ok, fiber_id} <- fiber_address(fiber) do
      case LifecycleService.resume(fiber_id) do
        {:ok, output} -> {:ok, output}
        {:error, _reason} -> args_for("resume", %{"fiber" => fiber_id}) |> then(&run_elem/1)
      end
    end
  end

  defp execute(action, %{"fiber" => fiber} = params)
       when action in ~w(pause set-model set-outcome uninstall) do
    with {:ok, fiber_id} <- fiber_address(fiber) do
      action
      |> args_for(%{params | "fiber" => fiber_id})
      |> run_elem()
    end
  end

  defp execute(action, params) do
    action
    |> args_for(params)
    |> run_elem()
  end

  defp refresh_card(%{"fiber" => fiber}) do
    case fiber_address(fiber) do
      {:ok, fiber_id} -> Shuttle.Poller.refresh_document(fiber_id)
      _ -> :ok
    end
  end

  defp refresh_card(_), do: :ok

  defp fiber_address(identifier) do
    case FeltStores.resolve_fiber(identifier) do
      {:ok, %{fiber_id: fiber_id}} -> {:ok, fiber_id}
      {:error, :not_found} -> {:error, "fiber not found: #{identifier}"}
    end
  end

  defp run_elem({:ok, args}), do: run(args)
  defp run_elem(error), do: error

  defp args_for("install", %{"fiber" => fiber} = params) do
    args = ["install", fiber]
    args = add_string_flag(args, "--model", params["model"])
    args = add_string_flag(args, "--project-dir", params["project_dir"])
    args = add_bool_flag(args, "--disabled", params["disabled"])
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

  # The outcome string round-trips as a single argv element, so multi-line
  # values (block scalars) survive without stdin piping. set-outcome refuses a
  # block-less fiber and runs `ensure_owned_here`, so a misrouted edit surfaces
  # a loud owner-mismatch rather than writing the wrong host's document.
  defp args_for("set-outcome", %{"fiber" => fiber, "outcome" => outcome})
       when is_binary(outcome),
       do: {:ok, ["set-outcome", fiber, "--outcome", outcome]}

  defp args_for("uninstall", %{"fiber" => fiber}), do: {:ok, ["uninstall", fiber]}
  defp args_for(action, _), do: {:error, "missing required fields for #{action}"}

  defp add_string_flag(args, _flag, nil), do: args
  defp add_string_flag(args, _flag, ""), do: args
  defp add_string_flag(args, flag, value), do: args ++ [flag, value]

  defp add_bool_flag(args, flag, true), do: args ++ [flag]
  defp add_bool_flag(args, _flag, _), do: args

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp run(args) do
    env = [{"SHUTTLE_LIFECYCLE_OFFLINE", "1"}]

    case System.cmd("shuttle-ctl", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:command_error, status, output}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end
end
