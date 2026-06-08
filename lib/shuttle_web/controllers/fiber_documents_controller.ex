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
    * `shuttle=true` — the owner-only kanban feed: return ONLY the fibers THIS
      daemon owns — a `shuttle:` block AND `shuttle.host == own_host_id`. A
      viewer reads this endpoint as a REMOTE origin and concatenates each
      owner's answer (never merges, because no fiber is authoritatively present
      on two hosts); a fiber pinned to another host belongs to that host's feed,
      never this one's git mirror. Also narrows the cross-tunnel transfer to the
      few hundred owned shuttle fibers. Omitted/unknown => unfiltered (every
      fiber, unowned included) — the content/search/graph readers, not the
      kanban feed.
  """

  use Phoenix.Controller, formats: [:json]

  def index(conn, params) do
    with_body? = Map.get(params, "body") in ["1", "true", true]
    shuttle_only? = Map.get(params, "shuttle") in ["1", "true", true]

    case list_fibers(with_body?, shuttle_only?) do
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

  defp list_fibers(false, true) do
    case Process.whereis(Shuttle.Poller) do
      nil ->
        Shuttle.FiberDocuments.list(with_body: false, shuttle_only: true)

      _pid ->
        case Shuttle.Poller.cached_fiber_documents() do
          {:ok, body} -> {:ok, body}
          {:error, _reason} -> Shuttle.FiberDocuments.list(with_body: false, shuttle_only: true)
        end
    end
  end

  defp list_fibers(with_body?, shuttle_only?) do
    Shuttle.FiberDocuments.list(with_body: with_body?, shuttle_only: shuttle_only?)
  end
end
