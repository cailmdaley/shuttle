defmodule ShuttleWeb.Router do
  @moduledoc """
  Router for the Shuttle Phoenix surface.

  Stage 5: Agent-API REST endpoints for worker coordination.
  """

  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api/v1", ShuttleWeb do
    pipe_through(:api)

    get("/workers/*fiber_id", WorkerController, :show)
    post("/dispatch", DispatchController, :create)
    get("/actions/*fiber_id", ActionsController, :show)
    post("/actions/resolve", ActionsController, :resolve)
    post("/actions/invoke", ActionsController, :invoke)
    post("/wait", WaitController, :create)
    post("/reserve", ReserveController, :create)
    get("/state", StateController, :show)
    get("/state/composite", StateController, :composite)
    get("/fibers", FiberDocumentsController, :index)
    get("/fibers/*id", FiberDocumentsController, :show)
    get("/origins", OriginsController, :show)
    post("/lifecycle", LifecycleController, :create)
    post("/felt-history", FeltHistoryController, :create)
    post("/felt-edit", FeltEditController, :create)
    get("/agents", AgentsController, :show)
    get("/version", VersionController, :show)
    post("/fiber/create", FiberController, :create)
    get("/fiber/host", FiberHostController, :show)
    post("/felt-stores", FeltStoresController, :create)
    post("/cache/bust", CacheBustController, :create)
  end
end
