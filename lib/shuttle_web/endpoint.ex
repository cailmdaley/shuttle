defmodule ShuttleWeb.Endpoint do
  @moduledoc """
  Minimal Phoenix endpoint for the reactive snapshot surface.

  Serves WebSocket connections for Phoenix Channels only.
  No static files, no sessions, no HTML — just the snapshot channel.
  """

  use Phoenix.Endpoint, otp_app: :shuttle

  @session_options [
    store: :cookie,
    key: "_shuttle_key",
    signing_salt: "shuttlesalt",
    same_site: "Lax"
  ]

  socket "/socket", ShuttleWeb.UserSocket,
    websocket: true,
    longpoll: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug ShuttleWeb.CORSPlug
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ShuttleWeb.Router
end
