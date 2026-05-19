defmodule ShuttleWeb.FiberController do
  @moduledoc """
  Agent-API endpoint for daemon-local fiber creation.

  Cross-host callers choose the target daemon before calling this endpoint; the
  controller itself writes only to this daemon's local felt store.
  """

  use Phoenix.Controller, formats: [:json]

  alias Shuttle.FeltStores

  def create(conn, params) do
    with {:ok, fiber_id} <- required_string(params, "id"),
         {:ok, name} <- required_string(params, "name"),
         {:ok, body} <- optional_string(params, "body", ""),
         {:ok, frontmatter} <- normalize_frontmatter(params, name),
         {:ok, frontmatter} <- normalize_shuttle_host(frontmatter),
         :ok <- validate_shuttle(frontmatter["shuttle"]),
         {:ok, path} <- fiber_path(fiber_id),
         :ok <- ensure_new(path),
         :ok <- write_fiber(path, frontmatter, body) do
      json(conn, %{id: fiber_id, path: path})
    else
      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{error: reason})
    end
  end

  defp normalize_frontmatter(params, name) do
    case Map.get(params, "frontmatter", %{}) do
      frontmatter when is_map(frontmatter) ->
        {:ok,
         frontmatter
         |> stringify_keys()
         |> Map.put_new("name", name)
         |> Map.put_new("status", "active")}

      _ ->
        {:error, "frontmatter must be an object"}
    end
  end

  # Auto-stamp `host:` on new fibers with a shuttle block. Cross-host
  # blocks (an explicit `host:` that doesn't equal this daemon's identity)
  # are refused — the caller is asking the wrong daemon to write a file
  # for someone else's machine. See Shuttle.Poller.own_host_id/0 for the
  # resolution chain.
  defp normalize_shuttle_host(%{"shuttle" => shuttle} = frontmatter) when is_map(shuttle) do
    own_host = Shuttle.Poller.own_host_id()
    shuttle = stringify_keys(shuttle)

    case Map.get(shuttle, "host") do
      nil ->
        {:ok, %{frontmatter | "shuttle" => Map.put(shuttle, "host", own_host)}}

      "" ->
        {:ok, %{frontmatter | "shuttle" => Map.put(shuttle, "host", own_host)}}

      ^own_host ->
        {:ok, %{frontmatter | "shuttle" => shuttle}}

      other ->
        {:error,
         "shuttle.host #{inspect(other)} does not match this daemon host #{inspect(own_host)}"}
    end
  end

  defp normalize_shuttle_host(frontmatter), do: {:ok, frontmatter}

  defp validate_shuttle(nil), do: :ok

  defp validate_shuttle(shuttle) when is_map(shuttle) do
    cond do
      Map.get(shuttle, "enabled") != true ->
        :ok

      not is_binary(Map.get(shuttle, "project_dir")) or Map.get(shuttle, "project_dir") == "" ->
        {:error, "shuttle.project_dir is required when enabled=true"}

      not File.dir?(Path.expand(Map.fetch!(shuttle, "project_dir"))) ->
        {:error, "shuttle.project_dir does not exist on this host"}

      true ->
        :ok
    end
  end

  defp validate_shuttle(_), do: {:error, "shuttle must be an object"}

  defp fiber_path(fiber_id) do
    with :ok <- validate_fiber_id(fiber_id) do
      segments = String.split(fiber_id, "/")
      basename = List.last(segments)
      {:ok, Path.join([felt_root(), ".felt"] ++ segments ++ ["#{basename}.md"])}
    end
  end

  defp validate_fiber_id(fiber_id) do
    segments = String.split(fiber_id, "/")

    cond do
      fiber_id == "" ->
        {:error, "id is required"}

      String.starts_with?(fiber_id, "/") ->
        {:error, "id must be relative"}

      Enum.any?(segments, &(&1 in ["", ".", ".."])) ->
        {:error, "id contains an invalid path segment"}

      true ->
        :ok
    end
  end

  defp ensure_new(path) do
    if File.exists?(path), do: {:error, "fiber already exists"}, else: :ok
  end

  defp write_fiber(path, frontmatter, body) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    payload = ["---\n", yaml(frontmatter), "---\n", body, ensure_trailing_newline(body)]

    with :ok <- File.write(tmp, payload),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> {:error, "writing fiber: #{:file.format_error(reason)}"}
    end
  end

  defp felt_root do
    FeltStores.configured_hosts()
    |> List.first()
  end

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} is required"}
    end
  end

  defp optional_string(params, key, default) do
    case Map.get(params, key, default) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "#{key} must be a string"}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

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
      String.match?(value, ~r/^[A-Za-z0-9_\/.\-:@]+$/) -> value
      true -> inspect(value)
    end
  end

  defp yaml_scalar(value), do: inspect(value)

  defp spaces(n), do: String.duplicate(" ", n)
  defp ensure_trailing_newline(""), do: ""
  defp ensure_trailing_newline(body), do: if(String.ends_with?(body, "\n"), do: "", else: "\n")
end
