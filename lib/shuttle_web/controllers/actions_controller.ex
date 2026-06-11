defmodule ShuttleWeb.ActionsController do
  @moduledoc """
  Shuttle-owned lifecycle action classification for external views.
  """

  use Phoenix.Controller, formats: [:json]

  alias Shuttle.{ActionQueries, Actions, Transition}

  def show(conn, %{"fiber_id" => parts}) do
    fiber_id = Path.join(parts)

    case ActionQueries.actions_for(fiber_id) do
      {:ok, actions} ->
        json(conn, %{fiber_id: fiber_id, actions: actions})

      {:error, reason} ->
        conn |> put_status(404) |> json(%{fiber_id: fiber_id, error: render_error(reason)})
    end
  end

  def resolve(conn, %{"fiber" => fiber, "target" => target}) when is_map(fiber) do
    fiber_id = Map.get(fiber, "id")
    running? = Map.get(fiber, "running", false) == true

    case Actions.resolve_transition(fiber, target, running?) do
      {:ok, action} ->
        json(conn, %{fiber_id: fiber_id, target: target, action: action})

      {:error, :unknown_target} ->
        conn
        |> put_status(400)
        |> json(%{fiber_id: fiber_id, target: target, error: "unknown_target"})
    end
  end

  def resolve(conn, %{"fiber_id" => fiber_id, "target" => target}) do
    case ActionQueries.resolve_action(fiber_id, target) do
      {:ok, action} ->
        json(conn, %{fiber_id: fiber_id, target: target, action: action})

      {:error, :unknown_target} ->
        conn
        |> put_status(400)
        |> json(%{fiber_id: fiber_id, target: target, error: "unknown_target"})

      {:error, reason} ->
        conn
        |> put_status(404)
        |> json(%{fiber_id: fiber_id, target: target, error: render_error(reason)})
    end
  end

  def resolve(conn, _params) do
    conn |> put_status(400) |> json(%{error: "fiber or fiber_id, plus target, are required"})
  end

  # The invoke pipeline (validate → availability → mutate) and its HTTP-status
  # mapping live in `Shuttle.Transition`, shared with the unified `/transition`
  # endpoint so there is one implementation.
  def invoke(conn, %{"fiber_id" => fiber_id, "action" => action}) do
    case Transition.invoke(fiber_id, action) do
      :ok ->
        json(conn, %{fiber_id: fiber_id, action: action, invoked: true})

      {:error, reason} ->
        {status, error} = Transition.http_error(reason)

        conn
        |> put_status(status)
        |> json(%{fiber_id: fiber_id, action: action, invoked: false, error: error})
    end
  end

  def invoke(conn, _params) do
    conn |> put_status(400) |> json(%{error: "fiber_id and action are required"})
  end

  defp render_error(reason) when is_binary(reason), do: reason
  defp render_error(reason) when is_atom(reason), do: to_string(reason)
  defp render_error(reason), do: inspect(reason)
end
