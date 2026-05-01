defmodule ShuttleWeb.StateController do
  @moduledoc """
  Agent-API endpoint: GET /api/v1/state

  Returns the full orchestrator state including running workers,
  retry queue, reservations, and waiters.
  """

  use Phoenix.Controller, formats: [:json]

  def show(conn, _params) do
    state = Shuttle.Poller.orchestrator_state()
    json(conn, state)
  end
end
