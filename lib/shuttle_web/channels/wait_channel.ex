defmodule ShuttleWeb.WaitChannel do
  @moduledoc """
  Per-fiber Phoenix Channel for wait-for-tempered notifications.

  Topic: `shuttle:wait:<fiber_id>`
  """

  use Phoenix.Channel

  @impl true
  def join("shuttle:wait:" <> _fiber_id, _payload, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_info(%{event: event} = payload, socket) when is_binary(event) do
    push(socket, event, Map.delete(payload, :event))
    {:noreply, socket}
  end
end
