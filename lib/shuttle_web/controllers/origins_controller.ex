defmodule ShuttleWeb.OriginsController do
  @moduledoc """
  Agent-API endpoint for daemon origin resolution.

  `GET /api/v1/origins` exposes the local daemon plus the configured
  `:remotes` list. The Go CLI uses this as the single source of truth
  for `--origin <name>` URL routing.
  """

  use Phoenix.Controller, formats: [:json]

  def show(conn, _params) do
    origins =
      [%{name: "local", url: local_url()}] ++
        (Application.get_env(:shuttle, :remotes, [])
         |> Enum.map(&render_remote/1)
         |> Enum.reject(&is_nil/1))

    json(conn, %{origins: origins})
  end

  defp local_url do
    endpoint = Application.get_env(:shuttle, ShuttleWeb.Endpoint, [])
    port = get_in(endpoint, [:http, :port]) || 4000
    "http://127.0.0.1:#{port}"
  end

  defp render_remote(%Shuttle.Remote{name: name, url: url}), do: %{name: name, url: url}
  defp render_remote(%{name: name, url: url}), do: %{name: name, url: url}
  defp render_remote(%{"name" => name, "url" => url}), do: %{name: name, url: url}
  defp render_remote(_), do: nil
end
