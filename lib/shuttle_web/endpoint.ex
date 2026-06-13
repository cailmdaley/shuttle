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

  # Serve the built Shuttle UI bundle so the daemon is one process (API + UI).
  # `only:` restricts to the bundle's first-segment dirs/files, so `/api/*`,
  # `/socket`, and the bare `/` fall through to the router (which serves
  # `index.html` via SpaController). A missing bundle just 404s the asset — the
  # API stays fully usable.
  plug Plug.Static,
    at: "/",
    from: ShuttleWeb.Assets.dist(),
    only: ~w(assets fonts index.html paper.html favicon.ico)

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
