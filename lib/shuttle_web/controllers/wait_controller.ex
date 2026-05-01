defmodule ShuttleWeb.WaitController do
  @moduledoc """
  Agent-API endpoint: POST /api/v1/wait

  Requests notification when a fiber reaches `tempered: true`.
  Returns immediately; the caller subscribes to
  `shuttle:wait:<fiber_id>` for the tempered event.
  """

  use Phoenix.Controller, formats: [:json]

  def create(conn, params) do
    fiber_id = Map.get(params, "fiber_id")
    timeout_ms = Map.get(params, "timeout_ms", 3_600_000)

    if is_nil(fiber_id) do
      conn
      |> put_status(400)
      |> json(%{error: "fiber_id is required"})
    else
      channel_topic = "shuttle:wait:#{fiber_id}"

      case Shuttle.Poller.wait_for_tempered(fiber_id, timeout_ms, channel_topic: channel_topic) do
        {:ok, :already_tempered} ->
          json(conn, %{
            accepted: true,
            status: "already_tempered",
            fiber_id: fiber_id,
            channel_topic: channel_topic
          })

        {:ok, :monitoring} ->
          json(conn, %{
            accepted: true,
            status: "monitoring",
            fiber_id: fiber_id,
            channel_topic: channel_topic
          })

        {:error, reason} ->
          conn
          |> put_status(500)
          |> json(%{accepted: false, reason: inspect(reason)})
      end
    end
  end
end
