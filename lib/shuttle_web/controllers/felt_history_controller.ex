defmodule ShuttleWeb.FeltHistoryController do
  @moduledoc """
  Daemon-local felt history writes for host-routed Shuttle launches.

  Portolan uses this before dispatching through a remote daemon so
  review-comment directives land in the same loom the worker will read.
  """

  use Phoenix.Controller, formats: [:json]

  alias Shuttle.FeltStores

  def create(conn, %{"fiber_id" => fiber_id, "kind" => kind, "summary" => summary} = params)
      when is_binary(fiber_id) and is_binary(kind) and is_binary(summary) do
    with {:ok, host} <- host_for_fiber(fiber_id),
         {:ok, output} <- run(host, fiber_id, kind, summary, Map.get(params, "fields", %{})) do
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
    |> send_resp(400, "fiber_id, kind, and summary are required")
  end

  defp host_for_fiber(fiber_id) do
    FeltStores.configured_hosts()
    |> Enum.find(&fiber_exists?(&1, fiber_id))
    |> case do
      nil -> {:error, "fiber not found: #{fiber_id}"}
      host -> {:ok, host}
    end
  end

  defp fiber_exists?(host, fiber_id) do
    case exact_fiber_path(host, fiber_id) do
      {:ok, _path} -> true
      {:error, _} -> false
    end
  end

  defp exact_fiber_path(host, fiber_id) do
    segments = String.split(fiber_id, "/")
    basename = List.last(segments)
    felt_dir = Path.join(host, ".felt")
    bare_path = Path.join(felt_dir, "#{basename}.md")
    dir_path = Path.join([felt_dir | segments] ++ ["#{basename}.md"])

    cond do
      not String.contains?(fiber_id, "/") and File.exists?(bare_path) -> {:ok, bare_path}
      File.exists?(dir_path) -> {:ok, dir_path}
      true -> {:error, :not_found}
    end
  end

  defp run(host, fiber_id, kind, summary, fields) do
    args = ["-C", host, "history", "append", fiber_id, "--kind", kind, "--summary", summary]

    args =
      fields
      |> normalize_fields()
      |> Enum.reduce(args, fn {key, value}, acc -> acc ++ ["--field", "#{key}=#{value}"] end)

    case System.cmd("felt", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:command_error, status, output}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  defp normalize_fields(fields) when is_map(fields) do
    fields
    |> Enum.filter(fn {key, value} -> is_binary(key) and is_scalar(value) end)
    |> Enum.map(fn {key, value} -> {key, to_string(value)} end)
  end

  defp normalize_fields(_), do: []

  defp is_scalar(value) when is_binary(value), do: true
  defp is_scalar(value) when is_number(value), do: true
  defp is_scalar(value) when is_boolean(value), do: true
  defp is_scalar(_), do: false
end
