defmodule ShuttleWeb.AgentsController do
  @moduledoc """
  Agent-API endpoint: GET /api/v1/agents

  Returns the agent registry as a JSON array, sourced from
  `Shuttle.Agents.list/0` (which embeds `share/agents.json` at compile time).
  External consumers fetch this instead of reading `share/agents.json` off
  disk — that decouples them from shuttle's filesystem layout.
  """

  use Phoenix.Controller, formats: [:json]

  def show(conn, _params) do
    json(conn, Shuttle.Agents.list())
  end
end
