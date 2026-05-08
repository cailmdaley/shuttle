defmodule ShuttleWeb.ActionsController do
  @moduledoc """
  Shuttle-owned lifecycle action classification for external views.
  """

  use Phoenix.Controller, formats: [:json]

  @timeout_ms 15_000

  def show(conn, %{"fiber_id" => parts}) do
    fiber_id = Path.join(parts)

    case Shuttle.Poller.actions_for(Shuttle.Poller, fiber_id, [], @timeout_ms) do
      {:ok, actions} ->
        json(conn, %{fiber_id: fiber_id, actions: actions})

      {:error, reason} ->
        conn |> put_status(404) |> json(%{fiber_id: fiber_id, error: render_error(reason)})
    end
  end

  def resolve(conn, %{"fiber_id" => fiber_id, "target" => target}) do
    case Shuttle.Poller.resolve_action(Shuttle.Poller, fiber_id, target, [], @timeout_ms) do
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
    conn |> put_status(400) |> json(%{error: "fiber_id and target are required"})
  end

  def invoke(conn, %{"fiber_id" => fiber_id, "action" => action}) do
    with :ok <- validate_action(action),
         :ok <- validate_available(fiber_id, action),
         :ok <- invoke_action(fiber_id, action) do
      json(conn, %{fiber_id: fiber_id, action: action, invoked: true})
    else
      {:error, :unknown_action} ->
        conn
        |> put_status(400)
        |> json(%{fiber_id: fiber_id, action: action, invoked: false, error: "unknown_action"})

      {:error, :action_not_available} ->
        conn
        |> put_status(409)
        |> json(%{
          fiber_id: fiber_id,
          action: action,
          invoked: false,
          error: "action_not_available"
        })

      {:error, {:command_error, status, output}} ->
        conn
        |> put_status(422)
        |> json(%{
          fiber_id: fiber_id,
          action: action,
          invoked: false,
          error: "shuttle exited #{status}: #{String.trim(output)}"
        })

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{
          fiber_id: fiber_id,
          action: action,
          invoked: false,
          error: render_error(reason)
        })
    end
  end

  def invoke(conn, _params) do
    conn |> put_status(400) |> json(%{error: "fiber_id and action are required"})
  end

  defp validate_action(action) do
    if Shuttle.Actions.known_action?(action), do: :ok, else: {:error, :unknown_action}
  end

  defp validate_available(fiber_id, action) do
    case Shuttle.Poller.actions_for(Shuttle.Poller, fiber_id, [], @timeout_ms) do
      {:ok, actions} ->
        if Enum.any?(actions, &(Map.get(&1, :id) == action || Map.get(&1, "id") == action)) do
          :ok
        else
          {:error, :action_not_available}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp invoke_action(fiber_id, "pause"), do: run(["pause", fiber_id])
  defp invoke_action(fiber_id, "reopen"), do: run(["reopen", fiber_id])
  defp invoke_action(fiber_id, "accept-run"), do: run(["accept", fiber_id])
  defp invoke_action(fiber_id, "continue-run-fresh"), do: run(["resume", fiber_id])
  defp invoke_action(fiber_id, "continue-run-previous"), do: run(["resume", fiber_id])
  defp invoke_action(fiber_id, "close-awaiting-review"), do: run(["close", fiber_id])
  defp invoke_action(fiber_id, "close-tempered"), do: run(["close", fiber_id, "--tempered=true"])

  defp invoke_action(fiber_id, "close-composted"),
    do: run(["close", fiber_id, "--tempered=false"])

  defp invoke_action(fiber_id, "dispatch-ad-hoc") do
    case Shuttle.Poller.dispatch_fiber(Shuttle.Poller, fiber_id,
           force: true,
           ad_hoc: true
         ) do
      {:ok, _session} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(args) do
    case System.cmd("shuttle-ctl", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:command_error, status, output}}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  defp render_error(reason) when is_binary(reason), do: reason
  defp render_error(reason) when is_atom(reason), do: to_string(reason)
  defp render_error(reason), do: inspect(reason)
end
