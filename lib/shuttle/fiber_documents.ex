defmodule Shuttle.FiberDocuments do
  @moduledoc """
  Daemon-local document reads for clients that need the owning host's fibers.

  Shuttle owns runtime state, but felt remains the document reader. This module
  shells out to `felt ls` for each configured store and returns the raw felt JSON
  entry plus enough path metadata for remote clients to render and mutate cards
  without relying on Portolan's WebSocket fiber-tree snapshots.
  """

  alias Shuttle.FeltStores

  @type entry :: %{
          required(:felt_store) => String.t(),
          required(:path) => String.t(),
          required(:fiber) => map(),
          optional(:report_path) => String.t()
        }

  @spec list(keyword()) :: {:ok, map()} | {:error, term()}
  def list(opts \\ []) do
    stores = Keyword.get_lazy(opts, :felt_stores, &FeltStores.configured_hosts/0)
    with_body? = Keyword.get(opts, :with_body, false)

    results = Enum.map(stores, &list_store(&1, with_body?))
    errors = Enum.flat_map(results, &store_errors/1)

    if errors == [] do
      entries =
        results
        |> Enum.flat_map(fn {:ok, rows} -> rows end)

      {:ok,
       %{
         host: own_host_id(),
         felt_stores: stores,
         generated_at: DateTime.to_iso8601(DateTime.utc_now()),
         fibers: entries
       }}
    else
      {:error, errors}
    end
  end

  defp list_store(store, with_body?) do
    args = ["ls", "-s", "all", "-j"]
    args = if with_body?, do: args ++ ["--body"], else: args

    case System.cmd("felt", args, cd: store, stderr_to_stdout: true) do
      {output, 0} ->
        decode_store(store, output)

      {output, status} ->
        {:error, %{felt_store: store, status: status, error: String.trim(output)}}
    end
  end

  defp decode_store(store, output) do
    with {:ok, decoded} when is_list(decoded) <- Jason.decode(output) do
      {:ok, decoded |> Enum.flat_map(&entry_for(store, &1))}
    else
      {:ok, _} -> {:error, %{felt_store: store, error: "felt ls returned non-list JSON"}}
      {:error, error} -> {:error, %{felt_store: store, error: Exception.message(error)}}
    end
  end

  defp entry_for(store, %{"id" => id} = fiber) when is_binary(id) and id != "" do
    path = relative_felt_path(fiber)
    full_path = Path.join([store, ".felt", path])

    entry = %{
      felt_store: store,
      path: path,
      fiber: fiber
    }

    report_path = full_path |> Path.dirname() |> Path.join("report.html")

    if File.exists?(report_path) do
      [Map.put(entry, :report_path, Path.expand(report_path))]
    else
      [entry]
    end
  end

  defp entry_for(_store, _fiber), do: []

  defp relative_felt_path(%{"id" => id, "entry_point" => true}) do
    "#{Path.basename(id)}.md"
  end

  defp relative_felt_path(%{"id" => id}) do
    Path.join(id, "#{Path.basename(id)}.md")
  end

  defp store_errors({:ok, _rows}), do: []
  defp store_errors({:error, error}), do: [error]

  defp own_host_id do
    case System.get_env("SHUTTLE_HOST") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        case :inet.gethostname() do
          {:ok, name} -> List.to_string(name)
          _ -> "unknown"
        end
    end
  end
end
