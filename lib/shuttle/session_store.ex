defmodule Shuttle.SessionStore do
  @moduledoc """
  Daemon-owned worker session handles backed by RuntimeStore.

  Session UUIDs are runtime handles for resuming a worker transcript. They are
  not part of the synced fiber document; this module stores them in the
  host-local runtime store and evicts legacy `shuttle.session` frontmatter when
  it sees it.
  """

  alias Shuttle.{FeltStores, RuntimeStore}

  @runtime_keys ~w(session)

  @spec set(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def set(fiber_id, session_id, agent_id \\ nil, opts \\ [])
      when is_binary(fiber_id) and is_binary(session_id) do
    with {:ok, path, frontmatter, body} <- read_fiber(fiber_id, opts),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         {:ok, lifecycle} <- build_set_lifecycle(fiber_id, shuttle, session_id, agent_id),
         :ok <- write_lifecycle_and_fiber(fiber_id, lifecycle, path, frontmatter, body) do
      {:ok, "session #{session_id} stored for #{fiber_id}\n"}
    end
  end

  defp build_set_lifecycle(fiber_id, shuttle, session_id, agent_id) do
    now = DateTime.utc_now()

    lifecycle =
      fiber_id
      |> lifecycle_metadata(shuttle)
      |> Map.put(:session, %{
        "id" => session_id,
        "agent" => agent_id || "",
        "dispatched_at" => DateTime.to_iso8601(now)
      })
      |> Map.put_new(:kind, Map.get(shuttle, "kind", Map.get(shuttle, "mode", "oneshot")))
      |> Map.put_new(:phase, "dispatched")

    {:ok, lifecycle}
  end

  @spec clear(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def clear(fiber_id, opts \\ []) when is_binary(fiber_id) do
    with {:ok, path, frontmatter, body} <- read_fiber(fiber_id, opts),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         {:ok, lifecycle, had_session?} <- build_clear_lifecycle(fiber_id, shuttle),
         :ok <-
           write_clear_lifecycle_and_fiber(
             fiber_id,
             lifecycle,
             had_session?,
             path,
             frontmatter,
             body
           ) do
      if had_session? or Map.has_key?(shuttle, "session") do
        {:ok, "session cleared for #{fiber_id}\n"}
      else
        {:ok, "#{fiber_id} has no session to clear\n"}
      end
    end
  end

  defp build_clear_lifecycle(fiber_id, shuttle) do
    lifecycle = lifecycle_metadata(fiber_id, shuttle)
    had_session? = get_in(lifecycle, [:session, "id"]) not in [nil, ""]

    lifecycle =
      if had_session? do
        lifecycle
        |> Map.delete(:session)
        |> Map.put_new(:kind, Map.get(shuttle, "kind", Map.get(shuttle, "mode", "oneshot")))
        |> Map.put_new(:phase, "scheduled")
      else
        lifecycle
      end

    {:ok, lifecycle, had_session?}
  end

  defp write_lifecycle_and_fiber(fiber_id, lifecycle, path, frontmatter, body) do
    RuntimeStore.upsert_lifecycle(runtime_store_path(), fiber_id, lifecycle)
    write_fiber(path, evict_runtime_keys(frontmatter), body)
  end

  defp write_clear_lifecycle_and_fiber(fiber_id, lifecycle, had_session?, path, frontmatter, body) do
    if had_session? do
      RuntimeStore.upsert_lifecycle(runtime_store_path(), fiber_id, lifecycle)
    end

    write_fiber(path, evict_runtime_keys(frontmatter), body)
  end

  defp lifecycle_metadata(fiber_id, shuttle) do
    runtime_store_path()
    |> RuntimeStore.list_lifecycle()
    |> Enum.find_value(%{}, fn
      %{fiber_id: ^fiber_id, metadata: metadata} -> metadata
      _ -> nil
    end)
    |> merge_legacy_session(shuttle)
  end

  defp merge_legacy_session(metadata, %{"session" => session}) when is_map(session) do
    Map.put_new(metadata, :session, session)
  end

  defp merge_legacy_session(metadata, _), do: metadata

  defp read_fiber(fiber_id, opts) do
    with {:ok, path} <- resolve_fiber_path(fiber_id, opts),
         {:ok, text} <- File.read(path),
         {:ok, frontmatter_yaml, body} <- split_frontmatter(text),
         {:ok, frontmatter} <- YamlElixir.read_from_string(frontmatter_yaml) do
      {:ok, path, stringify_keys(frontmatter || %{}), body}
    else
      {:error, :not_found} -> {:error, "fiber not found: #{fiber_id}"}
      {:error, reason} when is_atom(reason) -> {:error, to_string(reason)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp resolve_fiber_path(fiber_id, opts) do
    opts
    |> felt_stores()
    |> Enum.find_value(fn host ->
      case exact_fiber_path(host, fiber_id) do
        {:ok, path} -> path
        {:error, _} -> nil
      end
    end)
    |> case do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp felt_stores(opts) do
    case Keyword.get(opts, :felt_store) do
      store when is_binary(store) and store != "" -> [store]
      _ -> FeltStores.configured_hosts()
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

  defp split_frontmatter("---\n" <> rest) do
    case :binary.split(rest, "\n---", []) do
      [frontmatter, body] -> {:ok, frontmatter, body}
      _ -> {:error, "missing closing frontmatter delimiter"}
    end
  end

  defp split_frontmatter(_), do: {:error, "missing opening frontmatter delimiter"}

  defp shuttle_block(%{"shuttle" => shuttle}) when is_map(shuttle), do: {:ok, shuttle}
  defp shuttle_block(_), do: {:error, "fiber has no shuttle: block"}

  defp evict_runtime_keys(%{"shuttle" => shuttle} = frontmatter) do
    %{frontmatter | "shuttle" => Map.drop(shuttle, @runtime_keys)}
  end

  defp write_fiber(path, frontmatter, body) do
    tmp = path <> ".tmp"

    with :ok <-
           File.write(tmp, [
             "---\n",
             yaml(frontmatter),
             "---\n",
             body,
             ensure_trailing_newline(body)
           ]),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> {:error, "writing fiber: #{:file.format_error(reason)}"}
    end
  end

  defp runtime_store_path do
    System.get_env("SHUTTLE_RUNTIME_STORE") || RuntimeStore.default_path()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp yaml(map) do
    map
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map_join("", fn {key, value} -> yaml_field(key, value, 0) end)
  end

  defp yaml_field(key, value, indent) when is_map(value) do
    "#{spaces(indent)}#{key}:\n" <> yaml_nested(value, indent + 2)
  end

  defp yaml_field(key, value, indent) when is_list(value) do
    "#{spaces(indent)}#{key}:\n" <>
      Enum.map_join(value, "", fn item -> "#{spaces(indent + 2)}- #{yaml_scalar(item)}\n" end)
  end

  defp yaml_field(key, value, indent), do: "#{spaces(indent)}#{key}: #{yaml_scalar(value)}\n"

  defp yaml_nested(map, indent) do
    map
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map_join("", fn {key, value} -> yaml_field(key, value, indent) end)
  end

  defp yaml_scalar(value) when is_boolean(value), do: to_string(value)
  defp yaml_scalar(value) when is_integer(value), do: to_string(value)
  defp yaml_scalar(value) when is_float(value), do: to_string(value)
  defp yaml_scalar(nil), do: "null"

  defp yaml_scalar(value) when is_binary(value) do
    cond do
      value == "" -> ~s("")
      String.match?(value, ~r/^[A-Za-z0-9_\/.\-:@+]+$/) -> value
      true -> inspect(value)
    end
  end

  defp yaml_scalar(value), do: inspect(value)

  defp spaces(n), do: String.duplicate(" ", n)

  defp ensure_trailing_newline(""), do: ""
  defp ensure_trailing_newline(body), do: if(String.ends_with?(body, "\n"), do: "", else: "\n")
end
