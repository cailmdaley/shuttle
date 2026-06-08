defmodule Shuttle.FeltStores do
  @moduledoc """
  Reads and persists Shuttle's configured felt-store list.

  Resolution order:

    1. `LOOM_HOMES` (comma-separated)
    2. persisted `~/.shuttle/felt_stores.json`
    3. `LOOM_HOME`
    4. `~/loom`

  The persisted file stores only explicitly-registered hosts. Saving an empty
  list deletes the file so the default single-host fallback remains `~/loom`.
  """

  @config_env "SHUTTLE_FELT_STORES_FILE"
  @default_config_path "~/.shuttle/felt_stores.json"

  @type host_list :: [String.t()]

  @expanded_cache_key {__MODULE__, :expanded_hosts}
  @expanded_cache_ttl_ms 30_000

  @spec configured_hosts() :: host_list()
  def configured_hosts do
    base = base_hosts()
    now = System.monotonic_time(:millisecond)

    # Cache the symlink-following expansion by base config with a short TTL: the
    # store set + symlink topology change rarely, but `configured_hosts/0` is hot
    # (every poll, every fiber resolve), and a raw rescan costs ~20 ms on a
    # many-store host. Recompute on a config change (base differs) or once the TTL
    # lapses (so a newly-added substore symlink is picked up within 30 s without a
    # restart). The expansion only does filesystem reads, so a stale entry is at
    # worst 30 s out of date — never wrong, just late.
    case :persistent_term.get(@expanded_cache_key, :none) do
      {^base, expanded, cached_at} when now - cached_at < @expanded_cache_ttl_ms ->
        expanded

      _ ->
        expanded = expand_with_symlinked_substores(base)
        :persistent_term.put(@expanded_cache_key, {base, expanded, now})
        expanded
    end
  end

  defp base_hosts do
    case env_hosts() do
      [_ | _] = hosts ->
        hosts

      [] ->
        case registered_hosts() do
          [_ | _] = hosts -> hosts
          [] -> [default_host()]
        end
    end
  end

  @doc """
  Expand a store list with the project roots of any **symlinked substores**
  reachable from each store's `.felt/`.

  A project-canonical substore — candide's
  `~/loom/.felt/shapepipe -> /automnt/.../shapepipe/.felt` — is physically rooted
  *outside* the store it is linked into. The poller enumerates a fiber only from
  the store where its felt `path` physically roots (`run_shuttle_listing/2`'s
  `store_felt_realpath` prefix check), so the loom store correctly drops those
  fibers — and they vanish from the kanban unless the project root is *also* a
  configured store. Following the symlink here makes configuring just `~/loom`
  sufficient: the project root is auto-discovered, no per-substore config.

  For each store, scan `<store>/.felt/` for symlinks resolving to an external real
  `.felt/` directory and add its parent (the project root). Dedup is by
  `store_felt_realpath/1` — the same canonicalization the ownership check uses —
  so a store reached two ways (configured explicitly *and* discovered, or via two
  path spellings of the same real dir) is listed once. That dedup is load-bearing:
  two stores with the same `.felt` realpath would enumerate the same fibers and
  reintroduce the dispatch race the physical-rooting rule exists to prevent.
  Dangling symlinks and links resolving back inside the linking store are skipped.
  """
  @spec expand_with_symlinked_substores(host_list()) :: host_list()
  def expand_with_symlinked_substores(stores) do
    discovered = Enum.flat_map(stores, &symlinked_substore_roots/1)

    (stores ++ discovered)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq_by(&store_felt_realpath/1)
  end

  # Project roots of symlinked substores under `<store>/.felt/`: each `.felt/`
  # entry that is a symlink resolving to a real directory named `.felt` yields
  # that `.felt`'s parent. A root that lands back inside the linking store is
  # dropped (the store already enumerates it).
  defp symlinked_substore_roots(store) do
    felt_dir = Path.join(store, ".felt")

    case File.ls(felt_dir) do
      {:ok, entries} ->
        store_real = store_felt_realpath(store)

        entries
        |> Enum.flat_map(fn entry ->
          link = Path.join(felt_dir, entry)

          with {:ok, %File.Stat{type: :symlink}} <- File.lstat(link),
               {:ok, real} <- resolve_realpath(link),
               ".felt" <- Path.basename(real),
               true <- File.dir?(real),
               false <- inside?(real, store_real) do
            [Path.dirname(real)]
          else
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp inside?(path, prefix), do: path == prefix or String.starts_with?(path, prefix <> "/")

  @doc """
  Resolve which configured felt store owns `fiber_id`, as `{:ok, host}` or
  `{:error, :not_found}`. Thin wrapper over `resolve_fiber/1` returning just the
  owning store root.
  """
  @type resolved_fiber :: %{
          host: String.t(),
          fiber_id: String.t(),
          path: String.t(),
          uid: String.t() | nil
        }

  @spec host_for_fiber(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def host_for_fiber(fiber_id), do: host_for_fiber(fiber_id, configured_hosts())

  @spec host_for_fiber(String.t(), host_list()) :: {:ok, String.t()} | {:error, :not_found}
  def host_for_fiber(fiber_id, hosts) do
    case resolve_fiber(fiber_id, hosts) do
      {:ok, %{host: host}} -> {:ok, host}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Resolve a public fiber identifier to the felt address Shuttle can shell out to.

  Resolution asks felt for the answer — it never reconstructs the path from the
  id. For a slug address (the common case, including the symlinked "prefix-drop"
  topology) `felt show -j <addr>` resolves the fiber and carries its physical
  `path`, addressable `id`, and intrinsic `uid` directly. For a bare intrinsic
  ULID — which `felt show` cannot address — we scan each store's `felt ls -j`
  for the matching `uid` and read the carried `path` from that row. Either way
  the values come from felt's read chokepoint, not from guessing filesystem
  layouts.

  Returns `%{host, fiber_id, path, uid}` where `host` is the owning store root
  (for shelling subsequent felt commands), `fiber_id` is felt's addressable
  slug, `path` is the absolute on-disk file, and `uid` is the intrinsic identity
  when felt carries one.
  """
  @spec resolve_fiber(String.t()) :: {:ok, resolved_fiber()} | {:error, :not_found}
  def resolve_fiber(identifier) when is_binary(identifier),
    do: resolve_fiber(identifier, configured_hosts())

  @doc """
  As `resolve_fiber/1`, but resolves against an explicit `hosts` store list
  rather than the globally-configured stores. The Poller passes its own
  `state.felt_stores` so cold-path host resolution honors the exact store set
  that daemon instance is configured for (which may differ from the global
  `configured_hosts/0`, e.g. in tests or multi-store overrides).
  """
  @spec resolve_fiber(String.t(), host_list()) :: {:ok, resolved_fiber()} | {:error, :not_found}
  def resolve_fiber(identifier, hosts) when is_binary(identifier) and is_list(hosts) do
    with nil <- show_resolution(hosts, identifier),
         nil <- uid_resolution(hosts, identifier) do
      {:error, :not_found}
    else
      resolved -> {:ok, resolved}
    end
  end

  # Ask felt to resolve the address and carry the physical path, then assign
  # ownership by that path — NOT by which store happened to address it. felt's
  # JSON carries `path` (absolute, symlink-resolved), so the same physical file
  # resolves to the same path from every symlink view; the owning store is the
  # one whose realpath `.felt/` physically contains it. Re-querying felt against
  # the owner yields the owner-relative `id` (the address subsequent
  # `felt -C <owner>` commands need), instead of a symlink-view alias.
  defp show_resolution(hosts, identifier) do
    Enum.find_value(hosts, fn host ->
      case felt_show_json(host, identifier) do
        {:ok, %{"path" => path} = fiber} when is_binary(path) and path != "" ->
          owner = owning_store(hosts, path) || host
          owner_fiber = if owner == host, do: fiber, else: felt_for_path(owner, identifier, fiber)
          resolved_from(owner, owner_fiber)

        _ ->
          nil
      end
    end)
  end

  # `felt show` addresses fibers by slug, not by intrinsic ULID, so a bare UID
  # falls through to scanning each store's `felt ls -j` for a matching `uid`,
  # reading the carried `path`, and assigning ownership by that path. Skipped
  # entirely for non-ULID identifiers (those resolve via `show_resolution`).
  defp uid_resolution(hosts, uid) do
    if ulid?(uid) do
      Enum.find_value(hosts, fn host ->
        case felt_ls_json(host) do
          {:ok, rows} when is_list(rows) ->
            Enum.find_value(rows, fn
              %{"uid" => ^uid, "path" => path} = fiber when is_binary(path) and path != "" ->
                owner = owning_store(hosts, path) || host
                resolved_from(owner, fiber)

              _ ->
                nil
            end)

          _ ->
            nil
        end
      end)
    end
  end

  defp resolved_from(host, %{"id" => id, "path" => path} = fiber)
       when is_binary(id) and id != "" and is_binary(path) and path != "" do
    resolved(path, host, id, ulid_or_nil(Map.get(fiber, "uid")))
  end

  defp resolved_from(_host, _fiber), do: nil

  # The configured store that physically roots `path`: the one whose realpath
  # `.felt/` is a prefix of felt's carried (symlink-resolved) path. nil when no
  # configured store owns it (the caller keeps the queried store as a fallback).
  defp owning_store(hosts, path) do
    Enum.find(hosts, fn host ->
      String.starts_with?(path, store_felt_realpath(host) <> "/")
    end)
  end

  # Re-query the owner store so the returned `id` is owner-relative. Falls back
  # to the original fiber JSON if the owner can't address the identifier (it
  # always can for a physically-rooted fiber, but we degrade safely).
  defp felt_for_path(owner, identifier, fallback) do
    case felt_show_json(owner, identifier) do
      {:ok, %{"path" => _} = fiber} -> fiber
      _ -> fallback
    end
  end

  defp store_felt_realpath(host) do
    felt_dir = host |> Path.join(".felt") |> Path.expand()

    case resolve_realpath(felt_dir) do
      {:ok, resolved} -> resolved
      {:error, _} -> felt_dir
    end
  end

  @max_symlink_hops 40

  defp resolve_realpath(path) do
    case Path.split(Path.expand(path)) do
      ["/" | rest] -> resolve_realpath_segments("/", rest, 0)
      [first | rest] -> resolve_realpath_segments(first, rest, 0)
      [] -> {:error, :empty_path}
    end
  end

  defp resolve_realpath_segments(current, [], _hops), do: {:ok, current}

  defp resolve_realpath_segments(_current, _segments, hops) when hops > @max_symlink_hops,
    do: {:error, :symlink_loop}

  defp resolve_realpath_segments(current, [segment | rest], hops) do
    candidate = Path.join(current, segment)

    case :file.read_link(String.to_charlist(candidate)) do
      {:ok, target} ->
        target_path = List.to_string(target)

        expanded_target =
          case Path.type(target_path) do
            :absolute -> Path.expand(target_path)
            _ -> Path.expand(target_path, Path.dirname(candidate))
          end

        case Path.split(expanded_target) do
          ["/" | target_rest] -> resolve_realpath_segments("/", target_rest ++ rest, hops + 1)
          [first | target_rest] -> resolve_realpath_segments(first, target_rest ++ rest, hops + 1)
          [] -> {:error, :empty_target}
        end

      {:error, _} ->
        resolve_realpath_segments(candidate, rest, hops)
    end
  end

  defp felt_show_json(host, identifier) do
    # Never fold stderr into stdout: felt prints "no felt found matching …" to
    # stderr and JSON to stdout. A miss exits non-zero with empty stdout.
    case System.cmd("felt", ["-C", host, "show", identifier, "-j"], stderr_to_stdout: false) do
      {output, 0} -> Jason.decode(output)
      {_output, _status} -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  # `-s all` so a UID pointing at a closed/composted fiber still resolves; the
  # default `ls` filters to open/active. felt walks the tree and carries `uid`
  # and `path` per row, so no index build is required.
  defp felt_ls_json(host) do
    case System.cmd("felt", ["-C", host, "ls", "-j", "-s", "all"], stderr_to_stdout: false) do
      {output, 0} -> Jason.decode(output)
      {_output, _status} -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp resolved(path, host, fiber_id, uid) do
    %{host: host, fiber_id: fiber_id, path: path, uid: uid}
  end

  defp ulid_or_nil(value) when is_binary(value) do
    if ulid?(value), do: value, else: nil
  end

  defp ulid_or_nil(_), do: nil

  defp ulid?(value) when is_binary(value) do
    String.match?(value, ~r/^[0-9A-HJKMNP-TV-Z]{26}$/)
  end

  defp ulid?(_), do: false

  @spec registered_hosts() :: host_list()
  def registered_hosts do
    path = config_path()

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      case decoded do
        %{"felt_stores" => hosts} when is_list(hosts) -> normalize(hosts)
        hosts when is_list(hosts) -> normalize(hosts)
        _ -> []
      end
    else
      _ -> []
    end
  end

  @spec save(host_list()) :: {:ok, host_list()} | {:error, term()}
  def save(hosts) when is_list(hosts) do
    normalized = normalize(hosts)
    path = config_path()

    try do
      case normalized do
        [] ->
          case File.rm(path) do
            :ok -> {:ok, normalized}
            {:error, :enoent} -> {:ok, normalized}
            {:error, reason} -> {:error, {:file_error, reason}}
          end

        _ ->
          File.mkdir_p!(Path.dirname(path))
          tmp = path <> ".tmp"
          payload = Jason.encode!(%{version: 1, felt_stores: normalized}, pretty: true) <> "\n"
          File.write!(tmp, payload)
          File.rename!(tmp, path)
          {:ok, normalized}
      end
    rescue
      error -> {:error, error}
    end
  end

  @spec default_host() :: String.t()
  def default_host do
    case System.get_env("LOOM_HOME") do
      v when is_binary(v) and v != "" -> Path.expand(v)
      _ -> Path.join(System.user_home(), "loom")
    end
  end

  @spec config_path() :: String.t()
  def config_path do
    case System.get_env(@config_env) do
      v when is_binary(v) and v != "" -> Path.expand(v)
      _ -> Path.expand(@default_config_path)
    end
  end

  @spec env_hosts() :: host_list()
  def env_hosts do
    case System.get_env("LOOM_HOMES") do
      v when is_binary(v) and v != "" ->
        v
        |> String.split(",")
        |> normalize()

      _ ->
        []
    end
  end

  @spec normalize(list()) :: host_list()
  def normalize(hosts) do
    hosts
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end
end
