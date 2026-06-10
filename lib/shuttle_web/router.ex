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
    # Write-and-claim: register an externally-spawned live tmux session as a
    # fiber's running worker (capture sessions claim themselves here).
    post("/claim", ClaimController, :create)
    # Spawn-without-constitution: launch a capture session from a free-text
    # prompt; the session files the fiber and claims itself.
    post("/capture", CaptureController, :create)
    get("/actions/*fiber_id", ActionsController, :show)
    post("/actions/resolve", ActionsController, :resolve)
    post("/actions/invoke", ActionsController, :invoke)
    # The unified kanban write-plane: one call hides resolve + invoke +
    # owner-routing (local invoke, or forward to the owning remote daemon's
    # own /transition). Supersedes the kanban's prior two-leg resolve/invoke.
    post("/transition", TransitionController, :create)
    post("/wait", WaitController, :create)
    post("/reserve", ReserveController, :create)
    get("/state", StateController, :show)
    get("/state/composite", StateController, :composite)
    get("/fibers", FiberDocumentsController, :index)
    # Must precede the `/fibers/*id` wildcard, else "composite" resolves as a
    # fiber id. The unified cross-host board: local owner feed + cached remote
    # feeds, concatenated with reconciled per-host liveness.
    get("/fibers/composite", FiberDocumentsController, :composite)
    get("/fibers/*id", FiberDocumentsController, :show)
    get("/origins", OriginsController, :show)
    post("/lifecycle", LifecycleController, :create)
    post("/felt-history", FeltHistoryController, :create)
    post("/felt-edit", FeltEditController, :create)
    post("/felt-nest", FeltNestController, :create)
    get("/agents", AgentsController, :show)
    get("/version", VersionController, :show)
    post("/fiber/create", FiberController, :create)
    get("/fiber/host", FiberHostController, :show)
    post("/felt-stores", FeltStoresController, :create)
    post("/cache/bust", CacheBustController, :create)
  end
end
