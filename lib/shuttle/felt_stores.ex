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

  @spec configured_hosts() :: host_list()
  def configured_hosts do
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
  Resolve which configured felt store owns `fiber_id`, as `{:ok, host}` or
  `{:error, :not_found}`.

  The match criterion is the ONE canonical rule — `Shuttle.FiberId.canonical_id`
  (realpath → outermost `.felt` → slug) — the same derivation `/api/v1/fibers`
  and the runtime keying use, so id resolution never disagrees across daemon
  surfaces. Candidate files are generated cheaply (exact store path first; a
  glob-by-leaf only when that misses) and each candidate is *verified* by
  canonical id, so a leaf collision across stores still resolves to the right
  one.

  The glob fallback covers the "prefix-drop" topology: a project's `.felt`
  symlinked into loom (`loom/.felt/shapepipe → shapepipe/.felt`) makes the
  canonical id a bare leaf (`review-ngmix-v2-pr740`) while the file lives under
  the loom path (`shapepipe/review-ngmix-v2-pr740/...`). Exact construction from
  the leaf misses; the file is still discoverable by leaf and confirmed by
  canonical id. `felt` and the Go CLI's `resolveFiber` already resolve these, so
  the daemon must too — without it, host-routed lifecycle/actions verbs 400 with
  "fiber not found" on project-resident fibers.
  """
  @type resolved_fiber :: %{
          host: String.t(),
          fiber_id: String.t(),
          path: String.t(),
          uid: String.t() | nil
        }

  @spec host_for_fiber(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def host_for_fiber(fiber_id) do
    case resolve_fiber(fiber_id) do
      {:ok, %{host: host}} -> {:ok, host}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Resolve a public fiber identifier to the felt address Shuttle can shell out to.

  During the ULID migration, clients may send either the old slug-shaped felt
  address or the intrinsic frontmatter `id`. The resolver prefers the cheap slug
  path, then falls back to scanning configured stores for a matching ULID. It
  returns both surfaces: `fiber_id` is the felt CLI address, while `uid` is the
  intrinsic identity when present.
  """
  @spec resolve_fiber(String.t()) :: {:ok, resolved_fiber()} | {:error, :not_found}
  def resolve_fiber(identifier) when is_binary(identifier) do
    hosts = configured_hosts()

    with nil <- Enum.find_value(hosts, &exact_canonical_resolution(&1, identifier)),
         nil <- Enum.find_value(hosts, &nested_canonical_resolution(&1, identifier)),
         nil <- Enum.find_value(hosts, &uid_resolution(&1, identifier)) do
      {:error, :not_found}
    else
      resolved -> {:ok, resolved}
    end
  end

  defp exact_canonical_resolution(host, fiber_id) do
    segments = String.split(fiber_id, "/")
    leaf = List.last(segments)
    felt_dir = Path.join(host, ".felt")

    [
      # dir-contained: <.felt>/<segments>/<leaf>.md
      Path.join([felt_dir | segments] ++ ["#{leaf}.md"]),
      # flat: <.felt>/<segments>.md (covers both root-level and nested flat fibers)
      Path.join([felt_dir | segments]) <> ".md"
    ]
    |> Enum.find_value(&resolved_if_canonical(&1, host, fiber_id))
  end

  defp nested_canonical_resolution(host, fiber_id) do
    leaf = fiber_id |> String.split("/") |> List.last()
    felt_dir = Path.join(host, ".felt")

    # Match the fiber file by leaf anywhere under .felt. A felt fiber is always
    # `<leaf>.md` — flat (`<leaf>.md`) or dir-contained (`<leaf>/<leaf>.md`) —
    # and both end in `<leaf>.md`, so one glob covers both layouts (and crosses
    # symlinked/automounted sub-stores). Each candidate is verified by canonical
    # id, so over-matches are rejected.
    if File.dir?(felt_dir) do
      [felt_dir, "**", "#{leaf}.md"]
      |> Path.join()
      |> Path.wildcard(match_dot: true)
      |> Enum.find_value(&resolved_if_canonical(&1, host, fiber_id))
    end
  end

  defp resolved_if_canonical(path, host, fiber_id) do
    with true <- File.regular?(path),
         {:ok, ^fiber_id} <- Shuttle.FiberId.canonical_id(path) do
      resolved(path, host, fiber_id)
    else
      _ -> nil
    end
  end

  defp uid_resolution(host, uid) do
    felt_dir = Path.join(host, ".felt")

    if ulid?(uid) and File.dir?(felt_dir) do
      [felt_dir, "**", "*.md"]
      |> Path.join()
      |> Path.wildcard(match_dot: true)
      |> Enum.find_value(fn path ->
        with {:ok, ^uid} <- frontmatter_uid(path),
             {:ok, fiber_id} <- Shuttle.FiberId.canonical_id(path) do
          resolved(path, host, fiber_id, uid)
        else
          _ -> nil
        end
      end)
    end
  end

  defp resolved(path, host, fiber_id, uid \\ nil) do
    %{host: host, fiber_id: fiber_id, path: path, uid: uid || uid_from_path(path)}
  end

  defp uid_from_path(path) do
    case frontmatter_uid(path) do
      {:ok, uid} -> uid
      :error -> nil
    end
  end

  defp frontmatter_uid(path) do
    with {:ok, text} <- File.read(path),
         {:ok, yaml} <- frontmatter_yaml(text),
         {:ok, %{"id" => id}} when is_binary(id) <- YamlElixir.read_from_string(yaml),
         true <- ulid?(id) do
      {:ok, id}
    else
      _ -> :error
    end
  end

  defp frontmatter_yaml("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [yaml, _body] -> {:ok, yaml}
      _ -> :error
    end
  end

  defp frontmatter_yaml(_), do: :error

  defp ulid?(value) when is_binary(value) do
    String.match?(value, ~r/^[0-9A-HJKMNP-TV-Z]{26}$/)
  end

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
