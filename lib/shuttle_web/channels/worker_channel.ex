defmodule ShuttleWeb.WorkerChannel do
  @moduledoc """
  Per-worker Phoenix Channel for exit notifications.

  Topic: `shuttle:worker:<fiber_id>`

  Clients join to receive a push when the worker for that fiber exits.
  Used by the `confer` pattern and other agents that dispatch sub-fiber
  workers and need to know when they complete.
  """

  use Phoenix.Channel

  @impl true
  def join("shuttle:worker:" <> _fiber_id, _payload, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_info({:worker_exited, fiber_id, reason}, socket) do
    push(socket, "worker_exited", %{
      fiber_id: fiber_id,
      reason: inspect(reason)
    })

    {:noreply, socket}
  end
end
