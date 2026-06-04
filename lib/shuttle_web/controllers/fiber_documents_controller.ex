defmodule ShuttleWeb.FiberDocumentsController do
  @moduledoc """
  Agent-API endpoint for daemon-local fiber document reads.

  `GET /api/v1/fibers` returns the fibers visible to this daemon's configured
  felt stores. `GET /api/v1/fibers/:id` resolves a SINGLE fiber by canonical id
  — the per-fiber lookup Portolan uses to open a remote card without fetching
  every fiber. The `fiber` payload is felt JSON, intentionally leaving document
  parsing semantics with felt and Portolan's existing reader.

  Query params (both actions):
    * `body=true`    — include each fiber's markdown body.

  `GET /api/v1/fibers` only:
    * `shuttle=true` — return ONLY fibers carrying a `shuttle:` block (the
      subset Portolan's kanban needs). Lets the daemon serve the few hundred
      shuttle fibers instead of the several thousand it holds, collapsing the
      cross-tunnel transfer. Omitted/unknown => unfiltered (back-compatible).
  """

  use Phoenix.Controller, formats: [:json]

  def index(conn, params) do
    with_body? = Map.get(params, "body") in ["1", "true", true]
    shuttle_only? = Map.get(params, "shuttle") in ["1", "true", true]

    case Shuttle.FiberDocuments.list(with_body: with_body?, shuttle_only: shuttle_only?) do
      {:ok, body} ->
        json(conn, body)

      {:error, errors} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "felt_list_failed", stores: errors})
    end
  end

  @doc """
  `GET /api/v1/fibers/:id` — resolve one fiber by canonical id. The id is a
  wildcard splat so nested ids (`ai-futures/portolan/foo`) arrive as path
  segments; rejoin with `/`. Returns the same envelope shape as `index/2` with
  zero or one fiber, so Portolan reuses the list-response parser. A missing
  fiber is a 200 with `fibers: []`, not a 404 — the caller treats an empty list
  as "not here", same as scanning the full list would.
  """
  def show(conn, %{"id" => id_segments} = params) do
    id = id_segments |> List.wrap() |> Enum.join("/")
    with_body? = Map.get(params, "body") in ["1", "true", true]

    case Shuttle.FiberDocuments.get(id, with_body: with_body?) do
      {:ok, body} ->
        json(conn, body)

      {:error, errors} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "felt_show_failed", stores: errors})
    end
  end
end
