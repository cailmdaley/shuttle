defmodule ShuttleWeb.DispatchController do
  @moduledoc """
  Agent-API endpoint: POST /api/v1/dispatch

  Dispatches a sub-fiber worker. Used by the `confer` pattern:
  Worker A asks Shuttle to dispatch Worker B and subscribes to
  `shuttle:worker:<fiber_id>` for exit notification.
  """

  use Phoenix.Controller, formats: [:json]

  def create(conn, params) do
    fiber_id = Map.get(params, "fiber_id")
    notify_on_exit = Map.get(params, "notify_on_exit", false)
    force = truthy?(Map.get(params, "force", false))
    ad_hoc = truthy?(Map.get(params, "ad_hoc", false))

    if is_nil(fiber_id) do
      conn
      |> put_status(400)
      |> json(%{error: "fiber_id is required"})
    else
      case Shuttle.Poller.dispatch_fiber(fiber_id,
             notify_on_exit: notify_on_exit,
             force: force or ad_hoc,
             ad_hoc: ad_hoc
           ) do
        {:ok, session} ->
          json(conn, %{
            dispatched: true,
            fiber_id: fiber_id,
            tmux_session: session,
            notify_on_exit: notify_on_exit,
            channel_topic: "shuttle:worker:#{fiber_id}"
          })

        {:error, :already_running} ->
          conn
          |> put_status(409)
          |> json(%{dispatched: false, reason: "already_running", fiber_id: fiber_id})

        {:error, :not_eligible} ->
          conn
          |> put_status(422)
          |> json(%{dispatched: false, reason: "not_eligible", fiber_id: fiber_id})

        {:error, {:awaiting_review, run_id, completed_at}} ->
          conn
          |> put_status(422)
          |> json(%{
            dispatched: false,
            reason: "awaiting_review",
            fiber_id: fiber_id,
            run_id: run_id,
            completed_at: completed_at,
            message:
              "This role is awaiting review#{review_detail(run_id, completed_at)}. Accept first with `shuttle-ctl accept #{fiber_id}`, or use `shuttle-ctl resume #{fiber_id}` to continue the same run."
          })

        {:error, reason} ->
          conn
          |> put_status(500)
          |> json(%{dispatched: false, reason: inspect(reason), fiber_id: fiber_id})
      end
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  defp review_detail(run_id, completed_at) do
    parts =
      [
        if(is_binary(run_id) and run_id != "", do: "run #{run_id}"),
        if(is_binary(completed_at) and completed_at != "", do: "completed #{completed_at}")
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> ""
      _ -> " (" <> Enum.join(parts, ", ") <> ")"
    end
  end
end
