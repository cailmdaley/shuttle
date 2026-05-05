defmodule ShuttleWeb.StateController do
  @moduledoc """
  Agent-API endpoints for orchestrator state.

  * `GET /api/v1/state` — full local state (running workers, retry
    queue, reservations, waiters).

  * `GET /api/v1/state/composite` — local state plus per-origin remote
    snapshots, for the laptop's cross-host kanban view. See
    [[constitution-shuttle-remote-dispatch]].
  """

  use Phoenix.Controller, formats: [:json]

  def show(conn, _params) do
    state = Shuttle.Poller.orchestrator_state()
    json(conn, state)
  end

  def composite(conn, _params) do
    local = Shuttle.Poller.snapshot()
    remotes = Shuttle.RemoteRegistry.snapshots()

    body = %{
      local: local,
      remotes: render_remotes(remotes)
    }

    json(conn, body)
  end

  # Render remotes as a JSON-friendly map. `last_polled_at` is a
  # DateTime — serialize as an ISO8601 string for the kanban frontend.
  defp render_remotes(remotes) when is_map(remotes) do
    Map.new(remotes, fn {name, entry} ->
      {name, render_entry(entry)}
    end)
  end

  defp render_remotes(_), do: %{}

  defp render_entry(%{} = entry) do
    %{
      snapshot: Map.get(entry, :snapshot),
      last_polled_at: format_dt(Map.get(entry, :last_polled_at)),
      stale: Map.get(entry, :stale, true),
      last_error: render_error(Map.get(entry, :last_error))
    }
  end

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(_), do: nil

  # `:httpc` failure reasons are erlang terms (often tuples). Render as
  # a string so the JSON encoder doesn't need to know about them.
  defp render_error(nil), do: nil
  defp render_error(reason) when is_binary(reason), do: reason
  defp render_error(reason) when is_atom(reason), do: to_string(reason)
  defp render_error(reason), do: inspect(reason)
end
