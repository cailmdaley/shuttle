defmodule ShuttleWeb.FiberDocumentsController do
  @moduledoc """
  Agent-API endpoint for daemon-local fiber document reads.

  `GET /api/v1/fibers` returns the fibers visible to this daemon's configured
  felt stores. The `fiber` payload is felt JSON, intentionally leaving
  document parsing semantics with felt and Portolan's existing reader.
  """

  use Phoenix.Controller, formats: [:json]

  def index(conn, params) do
    with_body? = Map.get(params, "body") in ["1", "true", true]

    case Shuttle.FiberDocuments.list(with_body: with_body?) do
      {:ok, body} ->
        json(conn, body)

      {:error, errors} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "felt_list_failed", stores: errors})
    end
  end
end
