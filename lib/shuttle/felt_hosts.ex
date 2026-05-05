defmodule Shuttle.FeltHosts do
  @moduledoc """
  Reads and persists Shuttle's configured felt-host list.

  Resolution order:

    1. `LOOM_HOMES` (comma-separated)
    2. persisted `~/.shuttle/felt_hosts.json`
    3. `LOOM_HOME`
    4. `~/loom`

  The persisted file stores only explicitly-registered hosts. Saving an empty
  list deletes the file so the default single-host fallback remains `~/loom`.
  """

  @config_env "SHUTTLE_FELT_HOSTS_FILE"
  @default_config_path "~/.shuttle/felt_hosts.json"

  @type host_list :: [String.t()]

  @spec configured_hosts() :: host_list()
  def configured_hosts do
    case env_hosts() do
      [_ | _] = hosts -> hosts
      [] ->
        case registered_hosts() do
          [_ | _] = hosts -> hosts
          [] -> [default_host()]
        end
    end
  end

  @spec registered_hosts() :: host_list()
  def registered_hosts do
    path = config_path()

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      case decoded do
        %{"felt_hosts" => hosts} when is_list(hosts) -> normalize(hosts)
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
          payload = Jason.encode!(%{version: 1, felt_hosts: normalized}, pretty: true) <> "\n"
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
