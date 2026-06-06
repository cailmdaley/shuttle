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
    with {:ok, address, uid, path, frontmatter, body} <- read_fiber(fiber_id, opts),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         {:ok, lifecycle} <- build_set_lifecycle(address, uid, shuttle, session_id, agent_id),
         :ok <- write_lifecycle_and_fiber(address, lifecycle, path, frontmatter, body) do
      {:ok, "session #{session_id} stored for #{address}\n"}
    end
  end

  defp build_set_lifecycle(fiber_id, uid, shuttle, session_id, agent_id) do
    now = DateTime.utc_now()

    lifecycle =
      fiber_id
      |> lifecycle_metadata(uid, shuttle)
      |> put_uid(uid)
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
    with {:ok, address, uid, path, frontmatter, body} <- read_fiber(fiber_id, opts),
         {:ok, shuttle} <- shuttle_block(frontmatter),
         {:ok, lifecycle, had_session?} <- build_clear_lifecycle(address, uid, shuttle),
         :ok <-
           write_clear_lifecycle_and_fiber(
             address,
             lifecycle,
             had_session?,
             path,
             frontmatter,
             body
           ) do
      if had_session? or Map.has_key?(shuttle, "session") do
        {:ok, "session cleared for #{address}\n"}
      else
        {:ok, "#{address} has no session to clear\n"}
      end
    end
  end

  defp build_clear_lifecycle(fiber_id, uid, shuttle) do
    lifecycle = lifecycle_metadata(fiber_id, uid, shuttle)
    had_session? = get_in(lifecycle, [:session, "id"]) not in [nil, ""]

    lifecycle =
      if had_session? do
        lifecycle
        |> Map.delete(:session)
        |> put_uid(uid)
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

  defp lifecycle_metadata(fiber_id, uid, shuttle) do
    runtime_store_path()
    |> RuntimeStore.fetch_lifecycle(uid || fiber_id)
    |> Kernel.||(%{})
    |> merge_legacy_session(shuttle)
  end

  defp put_uid(metadata, uid) when is_binary(uid) and uid != "", do: Map.put(metadata, :uid, uid)
  defp put_uid(metadata, _), do: metadata

  defp merge_legacy_session(metadata, %{"session" => session}) when is_map(session) do
    Map.put_new(metadata, :session, session)
  end

  defp merge_legacy_session(metadata, _), do: metadata

  defp read_fiber(fiber_id, opts) do
    with {:ok, address, uid, path} <- resolve_fiber_path(fiber_id, opts),
         {:ok, text} <- File.read(path),
         {:ok, frontmatter_yaml, body} <- split_frontmatter(text),
         {:ok, frontmatter} <- YamlElixir.read_from_string(frontmatter_yaml) do
      {:ok, address, uid, path, stringify_keys(frontmatter || %{}), body}
    else
      {:error, :not_found} -> {:error, "fiber not found: #{fiber_id}"}
      {:error, reason} when is_atom(reason) -> {:error, to_string(reason)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp resolve_fiber_path(fiber_id, opts) do
    case Keyword.get(opts, :felt_store) do
      store when is_binary(store) and store != "" ->
        resolve_fiber_in_store(store, fiber_id)

      _ ->
        case FeltStores.resolve_fiber(fiber_id) do
          {:ok, %{fiber_id: address, uid: uid, path: path}} -> {:ok, address, uid, path}
          {:error, :not_found} -> {:error, :not_found}
        end
    end
  end

  # Scope resolution to the explicit `store` by resolving against that single
  # store rather than the globally-configured hosts. This honors the explicit-
  # store contract (the caller — e.g. the codex session-capture path — passes a
  # store that may not be globally configured) while still asking felt for the
  # answer: `resolve_fiber/2` reads felt's carried `path`/`id`/`uid` from the
  # named store, never reconstructing a path from the id.
  defp resolve_fiber_in_store(store, fiber_id) do
    case FeltStores.resolve_fiber(fiber_id, [store]) do
      {:ok, %{fiber_id: address, uid: uid, path: path}} -> {:ok, address, uid, path}
      {:error, :not_found} -> {:error, :not_found}
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
