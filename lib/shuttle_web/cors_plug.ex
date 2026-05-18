defmodule ShuttleWeb.CORSPlug do
  @moduledoc """
  Hand-rolled CORS plug for the Shuttle API endpoints.

  Allows the portolan kanban to call the daemon (127.0.0.1:4000) directly
  from the browser. Covers all endpoints the kanban hits: GET /api/v1/agents
  and POST /api/v1/dispatch.

  Origin matching is allowlist-based — the dev-server localhost variants
  AND the Tauri webview custom-protocol origins are admitted. The Tauri
  origins are required because the bundled Portolan.app loads from a
  custom protocol (not localhost:5173), so its fetches carry a non-http
  Origin that the dev-only allowlist used to reject — manifesting as
  "Load failed" / "Couldn't reach the Shuttle daemon" in the kanban modal
  despite the daemon actually being up.

  Requests from non-allowed origins pass through without CORS headers
  (the browser will block them).

  OPTIONS preflight requests are answered immediately with 204 and halted
  so they never reach the router. CORS response headers are appended to
  all other requests from allowed origins.
  """

  @behaviour Plug

  import Plug.Conn

  @allowed_origins [
    # Dev server (Vite + legacy :3000 fallback).
    "http://localhost:3000",
    "http://127.0.0.1:3000",
    "http://localhost:5173",
    "http://127.0.0.1:5173",
    # Bundled Tauri webview custom-protocol origins. macOS/Linux default
    # to `tauri://localhost`; Windows (and Tauri 2 with the `tauri.localhost`
    # form) uses the http variant. Both are added so the same build runs
    # cross-platform without a platform-specific shim.
    "tauri://localhost",
    "http://tauri.localhost",
    "https://tauri.localhost",
  ]

  @allowed_methods "GET, POST, OPTIONS"
  @allowed_headers "Content-Type, Accept"
  @max_age "3600"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
    |> put_cors_headers()
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, _opts) do
    put_cors_headers(conn)
  end

  defp put_cors_headers(conn) do
    origin = conn |> get_req_header("origin") |> List.first()

    if origin in @allowed_origins do
      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("access-control-allow-methods", @allowed_methods)
      |> put_resp_header("access-control-allow-headers", @allowed_headers)
      |> put_resp_header("access-control-max-age", @max_age)
      |> put_resp_header("vary", "Origin")
    else
      conn
    end
  end
end
