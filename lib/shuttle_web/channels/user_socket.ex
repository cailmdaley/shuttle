defmodule ShuttleWeb.UserSocket do
  @moduledoc """
  Socket handler for Shuttle Phoenix Channels.

  Clients join the `shuttle:snapshot` topic here to receive reactive state
  updates.
  """

  use Phoenix.Socket

  channel("shuttle:snapshot", ShuttleWeb.SnapshotChannel)
  channel("shuttle:worker:*", ShuttleWeb.WorkerChannel)
  channel("shuttle:wait:*", ShuttleWeb.WaitChannel)

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
