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
  Builds the wire entry for one felt JSON fiber.

  The poller uses this for its document cache so cached `/api/v1/fibers`
  responses preserve the same path, slug, logical-id, and report sibling
  semantics as the direct felt-list path.
  """
  @spec entries_for_fiber(String.t(), map()) :: [entry()]
  def entries_for_fiber(store, fiber), do: entry_for(store, fiber)

  @spec envelope([String.t()], [entry()]) :: map()
  def envelope(stores, entries) do
    %{
      host: own_host_id(),
      felt_stores: stores,
      generated_at: DateTime.to_iso8601(DateTime.utc_now()),
      fibers: entries
    }
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
      |> Enum.find(&entry_matches_id?(&1, id))

    cond do
      match != nil -> {:ok, envelope(stores, [match])}
      errors != [] -> {:error, errors}
      true -> {:ok, envelope(stores, [])}
    end
  end

  defp list_store(store, with_body?, shuttle_only?) do
    args = list_args(with_body?, shuttle_only?)

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

  defp list_args(true, _shuttle_only?) do
    ["ls", "-s", "all", "-j", "--body"]
  end

  defp list_args(false, true) do
    [
      "ls",
      "-s",
      "all",
      "-j",
      "--has-field",
      "shuttle",
      "--json-field",
      Enum.join(
        [
          "id",
          "uid",
          "name",
          "status",
          "tags",
          "created_at",
          "closed_at",
          "modified_at",
          "outcome",
          "due",
          "horizon",
          "cold",
          "kind",
          "priority",
          "depends_on",
          "tempered",
          "shuttle",
          "path"
        ],
        ","
      )
    ]
  end

  defp list_args(false, false), do: ["ls", "-s", "all", "-j"]

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
  defp shuttle_fiber?(%{"shuttle" => shuttle}) when is_map(shuttle) and map_size(shuttle) > 0,
    do: true

  defp shuttle_fiber?(_), do: false

  defp entry_for(store, %{"id" => id} = fiber) when is_binary(id) and id != "" do
    # Three values, all read from felt, none reverse-derived or guessed by Shuttle:
    #
    #   * The wire `path` is the SERVED-store-relative address Portolan opens the
    #     file by (`felt_store` + `path`). Portolan's `loomRelativeWirePath`
    #     depends on this served-relative shape, so it stays served-relative —
    #     but it is now READ from felt's carried `path` (its leaf shape) joined
    #     under felt's traversal `id` prefix, never guessed from `entry_point`.
    #     See `served_wire_path/1`.
    #
    #   * The card's `slug`/canonical id is the REALPATH store-relative slug
    #     (`review-ngmix`, where the bytes physically root), read from felt's
    #     carried absolute `path` — the same id `/state` keys the runtime by, so
    #     the kanban join matches.
    #
    #   * The card's logical `id` prefers felt's intrinsic `uid`, falling back to
    #     that canonical slug.
    wire_path = served_wire_path(fiber)
    canonical_id = canonical_id_from_path(fiber) || id
    logical_id = logical_id(fiber, canonical_id)

    fiber =
      fiber
      |> Map.put("id", logical_id)
      |> put_slug(canonical_id)

    entry = %{
      felt_store: store,
      path: wire_path,
      fiber: fiber
    }

    # report.html is a filesystem sibling of the fiber's `.md` — universally,
    # with no flat-vs-dir branch and no `entry_point` dependency. Read it from
    # the directory felt carries (`dirname(felt.path)`), the one path concept.
    # felt's `path` is symlink-canonicalized and already absolute, exactly the
    # form Portolan serves over /project-file/<originId><absPath>.
    case report_sibling(fiber) do
      {:ok, report_path} ->
        if File.exists?(report_path),
          do: [Map.put(entry, :report_path, report_path)],
          else: [entry]

      :error ->
        [entry]
    end
  end

  defp entry_for(_store, _fiber), do: []

  defp entry_matches_id?(%{fiber: %{"id" => id}}, id), do: true
  defp entry_matches_id?(%{fiber: %{"slug" => id}}, id), do: true
  defp entry_matches_id?(_, _), do: false

  defp put_slug(%{"id" => id} = fiber, id), do: fiber
  defp put_slug(fiber, slug), do: Map.put(fiber, "slug", slug)

  # Served-store-relative wire path, the address Portolan opens the file by
  # (`felt_store` + `path`). The PREFIX comes from felt's traversal `id` (which
  # carries the served-store prefix a symlink-traversed fiber's realpath drops);
  # the LEAF SHAPE — flat `<leaf>.md` vs dir-contained `<leaf>/<leaf>.md` — comes
  # from felt's carried `path`, not from an `entry_point` guess. The leaf shape
  # is symlink-invariant (the symlink swaps the prefix, never the leaf), so the
  # realpath tail and the served file agree on it. Falls back to the dir-contained
  # shape only when felt carries no usable `path` (older binaries).
  defp served_wire_path(%{"id" => id} = fiber) do
    leaf = Path.basename(id)
    prefix = Path.dirname(id)
    leaf_file = leaf_shape(fiber, leaf)

    if prefix == ".", do: leaf_file, else: Path.join(prefix, leaf_file)
  end

  # `<leaf>/<leaf>.md` when felt's carried path is dir-contained, else `<leaf>.md`.
  defp leaf_shape(%{"path" => path}, leaf) when is_binary(path) and path != "" do
    parent = path |> Path.dirname() |> Path.basename()
    if parent == leaf, do: Path.join(leaf, "#{leaf}.md"), else: "#{leaf}.md"
  end

  defp leaf_shape(_fiber, leaf), do: Path.join(leaf, "#{leaf}.md")

  # report.html beside the fiber file: `dirname(felt.path)/report.html`. felt's
  # `path` is absolute and symlink-canonicalized, so this is the real fiber dir
  # in every topology (dir-contained, symlinked-flat substore, entry point) with
  # no served-store-prefix coupling. `:error` when felt carries no `path`.
  defp report_sibling(%{"path" => path}) when is_binary(path) and path != "" do
    {:ok, Path.join(Path.dirname(Path.expand(path)), "report.html")}
  end

  defp report_sibling(_fiber), do: :error

  # Canonical (realpath store-relative) id from felt's carried absolute `path`:
  # the tail after the physically-enclosing `.felt/`, minus the `<leaf>.md`
  # filename for dir-contained fibers. For a symlink-traversed fiber this drops
  # the served-store prefix felt's traversal `id` carries, recovering the slug
  # the owning store (and `/state`) addresses. nil when felt carries no `path`
  # (older binaries) — the caller falls back to felt's traversal `id`.
  defp canonical_id_from_path(%{"path" => path}) when is_binary(path) and path != "" do
    case String.split(path, "/.felt/", parts: 2) do
      [_prefix, tail] when tail != "" -> canonical_id_from_tail(tail)
      _ -> nil
    end
  end

  defp canonical_id_from_path(_), do: nil

  # `<slug>/<leaf>.md` (dir-contained) → `<slug>`; `<leaf>.md` (flat) → `<leaf>`.
  defp canonical_id_from_tail(tail) do
    leaf = tail |> Path.basename() |> String.replace_suffix(".md", "")
    parent = tail |> Path.dirname()

    cond do
      parent == "." -> leaf
      Path.basename(parent) == leaf -> parent
      true -> Path.join(parent, leaf)
    end
  end

  defp logical_id(fiber, fallback) do
    case Map.get(fiber, "uid") do
      uid when is_binary(uid) ->
        if ulid?(uid), do: uid, else: fallback

      _ ->
        fallback
    end
  end

  defp ulid?(value) do
    String.match?(value, ~r/^[0-9A-HJKMNP-TV-Z]{26}$/)
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
