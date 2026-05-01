defmodule ShuttleWeb.Router do
  @moduledoc """
  Router for the Shuttle Phoenix surface.

  Stage 5: Agent-API REST endpoints for worker coordination.
  """

  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", ShuttleWeb do
    pipe_through :api

    get "/workers/*fiber_id", WorkerController, :show
    post "/dispatch", DispatchController, :create
    post "/wait", WaitController, :create
    post "/reserve", ReserveController, :create
    get "/state", StateController, :show
  end
end
