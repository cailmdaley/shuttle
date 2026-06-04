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
    shuttle_only? = Keyword.get(opts, :shuttle_only, false)

    results = Enum.map(stores, &list_store(&1, with_body?, shuttle_only?))
    errors = Enum.flat_map(results, &store_errors/1)

    if errors == [] do
      entries = Enum.flat_map(results, fn {:ok, rows} -> rows end)
      {:ok, envelope(stores, entries)}
    else
      {:error, errors}
    end
  end

  @doc """
  Resolve a SINGLE fiber by its canonical id without dragging in the whole
  store. This is the per-fiber dual of `list/1`: Portolan resolves a remote
  fiber's content/owner (kanban card → vellum view) through this instead of
  fetching every fiber and linear-scanning, collapsing a ~3.5MB cross-tunnel
  transfer to one fiber.

  Two-tier lookup:

    * **Fast path** — `felt show <id> -j` per store. For a fiber physically
      rooted in the store the canonical id equals felt's traversal id, so the
      direct show resolves in milliseconds.
    * **Scan fallback** — for a symlink-traversed fiber (loom's `.felt/shapepipe`
      → a separate project store) the canonical id drops the store prefix, so
      `felt show <canonical-id>` misses. We then reuse the `list/1` machinery to
      enumerate the store and match on the canonical id. This costs a full
      `felt ls` daemon-side but still returns a single fiber over the wire, and
      only fires for the handful of symlinked-out projects.

  Returns the same `{:ok, %{host, felt_stores, fibers: […]}}` envelope as
  `list/1` with zero or one fiber, so Portolan reuses the same response parser.
  A missing fiber is `{:ok, …, fibers: []}` (not an error); a felt failure
  during the scan fallback surfaces as `{:error, errors}`.
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(id, opts \\ []) do
    stores = Keyword.get_lazy(opts, :felt_stores, &FeltStores.configured_hosts/0)
    with_body? = Keyword.get(opts, :with_body, false)

    case fast_lookup(stores, id, with_body?) do
      {:ok, entry} -> {:ok, envelope(stores, [entry])}
      :miss -> scan_lookup(stores, id, with_body?)
    end
  end

  # Direct `felt show` per store; first store that resolves the id wins.
  defp fast_lookup(stores, id, with_body?) do
    Enum.find_value(stores, :miss, fn store ->
      case show_store(store, id, with_body?) do
        {:ok, [entry | _]} -> {:ok, entry}
        _ -> nil
      end
    end)
  end

  defp show_store(store, id, with_body?) do
    args = ["show", id, "-j"]
    args = if with_body?, do: args ++ ["--body"], else: args

    # Same stderr discipline as list_store: never fold stderr into stdout — felt
    # prints "no felt found matching …" (and parse warnings) to stderr while
    # emitting JSON on stdout. A missing fiber exits non-zero with empty stdout,
    # which we treat as "not in this store" and fall through to the next.
    case System.cmd("felt", args, cd: store) do
      {output, 0} ->
        case Jason.decode(output) do
          # `felt show -j` always emits `body`, even without `--body` (unlike
          # `felt ls -j`). Drop it when the caller didn't ask, so the metadata
          # path stays minimal and the response matches the list endpoint's
          # body=… contract.
          {:ok, %{} = fiber} ->
            fiber = if with_body?, do: fiber, else: Map.delete(fiber, "body")
            {:ok, entry_for(store, fiber)}

          _ ->
            :miss
        end

      {_output, _status} ->
        :miss
    end
  end

  # Enumerate each store and match the requested canonical id. Reuses list_store
  # so the entry shape (canonical id, store-relative path, report_path) is
  # byte-identical to the list endpoint.
  defp scan_lookup(stores, id, with_body?) do
    results = Enum.map(stores, &list_store(&1, with_body?, false))
    errors = Enum.flat_map(results, &store_errors/1)

    match =
      results
      |> Enum.flat_map(fn
        {:ok, rows} -> rows
        _ -> []
      end)
      |> Enum.find(&(&1.fiber["id"] == id))

    cond do
      match != nil -> {:ok, envelope(stores, [match])}
      errors != [] -> {:error, errors}
      true -> {:ok, envelope(stores, [])}
    end
  end

  defp envelope(stores, entries) do
    %{
      host: own_host_id(),
      felt_stores: stores,
      generated_at: DateTime.to_iso8601(DateTime.utc_now()),
      fibers: entries
    }
  end

  defp list_store(store, with_body?, shuttle_only?) do
    args = ["ls", "-s", "all", "-j"]
    args = if with_body?, do: args ++ ["--body"], else: args

    # Do NOT fold stderr into stdout: felt prints `warning: failed to parse …`
    # for stray non-fiber `.md` files (SPEC.md, README.md) to stderr while still
    # emitting valid JSON on stdout and exiting 0. Capturing stderr would prepend
    # those warnings to the JSON and break Jason.decode for the whole store —
    # 500ing the entire /fibers endpoint. Felt's warnings land in the daemon log
    # instead; only stdout is parsed.
    case System.cmd("felt", args, cd: store) do
      {output, 0} ->
        decode_store(store, output, shuttle_only?)

      {output, status} ->
        {:error, %{felt_store: store, status: status, error: String.trim(output)}}
    end
  end

  defp decode_store(store, output, shuttle_only?) do
    with {:ok, decoded} when is_list(decoded) <- Jason.decode(output) do
      rows = if shuttle_only?, do: Enum.filter(decoded, &shuttle_fiber?/1), else: decoded
      {:ok, rows |> Enum.flat_map(&entry_for(store, &1))}
    else
      {:ok, _} -> {:error, %{felt_store: store, error: "felt ls returned non-list JSON"}}
      {:error, error} -> {:error, %{felt_store: store, error: Exception.message(error)}}
    end
  end

  # A fiber is kanban-relevant to Portolan iff it carries a non-empty `shuttle:`
  # block. Filtering here — before entry_for's realpath + report.html stat — lets
  # a remote daemon serve the few hundred shuttle fibers Portolan's kanban needs
  # instead of the several thousand it holds, collapsing the cross-tunnel transfer
  # that dominated kanban cold-load. An un-upgraded daemon simply ignores the
  # `?shuttle=` query param and returns everything, so the Portolan side degrades
  # gracefully (no speedup, no breakage). Non-shuttle due-dated todos are a
  # Portolan-local concern and never live on a remote, so this drops nothing the
  # kanban shows.
  defp shuttle_fiber?(%{"shuttle" => shuttle}) when is_map(shuttle) and map_size(shuttle) > 0, do: true
  defp shuttle_fiber?(_), do: false

  defp entry_for(store, %{"id" => id} = fiber) when is_binary(id) and id != "" do
    # `path` (and thus the physical file location) is derived from felt's
    # traversal id *before* we overwrite `id` — it stays store-relative so
    # remote clients open the file via `felt_store` + `path`. The card's logical
    # `id`, by contrast, is canonicalized: realpath → enclosing .felt → slug,
    # the one rule shared with /state runtime keying. For a fiber physically
    # rooted in this store the two coincide; for a symlink-traversed fiber (loom
    # walking through `loom/.felt/shapepipe → project/.felt`) the canonical id
    # drops the store prefix to match the project-relative runtime key.
    path = relative_felt_path(fiber)
    full_path = Path.join([store, ".felt", path])

    entry = %{
      felt_store: store,
      path: path,
      fiber: Map.put(fiber, "id", canonical_id(full_path, id))
    }

    report_path = full_path |> Path.dirname() |> Path.join("report.html")

    if File.exists?(report_path) do
      [Map.put(entry, :report_path, Path.expand(report_path))]
    else
      [entry]
    end
  end

  defp entry_for(_store, _fiber), do: []

  defp canonical_id(full_path, fallback) do
    case Shuttle.FiberId.canonical_id(full_path) do
      {:ok, id} -> id
      {:error, _} -> fallback
    end
  end

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
