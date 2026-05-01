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

    if is_nil(fiber_id) do
      conn
      |> put_status(400)
      |> json(%{error: "fiber_id is required"})
    else
      case Shuttle.Poller.dispatch_fiber(fiber_id, notify_on_exit: notify_on_exit) do
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

        {:error, reason} ->
          conn
          |> put_status(500)
          |> json(%{dispatched: false, reason: inspect(reason), fiber_id: fiber_id})
      end
    end
  end
end
