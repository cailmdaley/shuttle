defmodule ShuttleWeb.Router do
  @moduledoc """
  Minimal router for the Shuttle Phoenix surface.

  Stage 4: no HTTP routes yet — only the WebSocket channel.
  Stage 5 will add the agent-API REST endpoints here.
  """

  use Phoenix.Router

  # Agent-API routes will be added in Stage 5
  # scope "/api/v1", ShuttleWeb do
  #   pipe_through :api
  #   get "/workers/:fiber_id", WorkerController, :show
  #   post "/dispatch", DispatchController, :create
  #   post "/wait", WaitController, :create
  #   post "/reserve", ReserveController, :create
  #   get "/state", StateController, :show
  # end
end
