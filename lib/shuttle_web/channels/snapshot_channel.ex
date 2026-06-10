defmodule ShuttleWeb.SnapshotChannel do
  @moduledoc """
  Phoenix Channel broadcasting Shuttle orchestrator state changes.

  Topic: `shuttle:snapshot`

  Clients join to receive push updates whenever:
  - A worker is dispatched
  - A worker exits
  - A worker's state changes (activity, token update)
  - A retry is scheduled
  - A fiber's eligibility changes

  The push payload is the full JSON snapshot shape defined in SPEC §11.2.
  """

  use Phoenix.Channel

  @impl true
  def join("shuttle:snapshot", _payload, socket) do
    # Send current snapshot immediately on join
    snap =
      try do
        Shuttle.Poller.snapshot()
      catch
        :exit, _ ->
          %{
            poll_at: DateTime.to_unix(DateTime.utc_now(), :millisecond),
            host: Shuttle.Poller.own_host_id(),
            eligible: [],
            blocked: [],
            orphans: [],
            retrying: [],
            claimed_count: 0,
            max_concurrent: 0
          }
      end

    {:ok, snap, socket}
  end

  @impl true
  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{pong: true}}, socket}
  end

  @impl true
  def handle_info({:snapshot, snap}, socket) do
    push(socket, "snapshot", snap)
    {:noreply, socket}
  end
end
