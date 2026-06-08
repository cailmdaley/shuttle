defmodule ShuttleWeb.FeltEditController do
  @moduledoc """
  Daemon-local felt-document surface edits for host-routed kanban cards.

  The owner-only kanban feed serves a fiber only when its `shuttle.host`
  resolves to this daemon, so a viewer's tag edit on a remote-owned card routes
  here over the SSH tunnel instead of editing the viewer's own loom mirror.
  Single-writer at the document holds: the owner daemon is the lone writer of a
  fiber it owns, and `felt edit` is the single felt-native tag writer (the same
  CLI Portolan shells for local cards).

  `POST /api/v1/felt-edit` body: `{ "fiber_id": "...", "add": [...],
  "remove": [...] }`. An empty diff is a 200 no-op.
  """

  use Phoenix.Controller, formats: [:json]

  alias Shuttle.FeltStores

  def create(conn, %{"fiber_id" => fiber_id} = params) when is_binary(fiber_id) do
    add = string_list(params["add"])
    remove = string_list(params["remove"])

    with {:ok, host, address} <- host_for_fiber(fiber_id),
         {:ok, output} <- run(host, address, add, remove) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, output)
    else
      {:error, reason} when is_binary(reason) ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, reason)

      {:command_error, status, output} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(422, "felt exited #{status}: #{output}")
    end
  end

  def create(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "fiber_id is required")
  end

  defp host_for_fiber(fiber_id) do
    case FeltStores.resolve_fiber(fiber_id) do
      {:ok, %{host: host, fiber_id: address}} -> {:ok, host, address}
      {:error, :not_found} -> {:error, "fiber not found: #{fiber_id}"}
    end
  end

  # An empty diff is a no-op, mirroring Portolan's local `runFeltTagEdit`.
  defp run(_host, _fiber_id, [], []), do: {:ok, ""}

  defp run(host, fiber_id, add, remove) do
    args = ["-C", host, "edit", fiber_id]
    args = Enum.reduce(remove, args, fn tag, acc -> acc ++ ["--untag", tag] end)
    args = Enum.reduce(add, args, fn tag, acc -> acc ++ ["--tag", tag] end)

    case System.cmd("felt", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:command_error, status, output}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  defp string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(_), do: []
end
