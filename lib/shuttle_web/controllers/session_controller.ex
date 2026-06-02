defmodule ShuttleWeb.SessionController do
  @moduledoc """
  Daemon-local worker session handle mutations.

  External callers use this endpoint instead of writing `shuttle.session` into
  synced frontmatter. The daemon stores the handle in RuntimeStore and evicts
  any legacy frontmatter copy from the document.
  """

  use Phoenix.Controller, formats: [:json]

  alias Shuttle.SessionStore

  def create(conn, %{"action" => "set", "fiber" => fiber, "session_id" => session_id} = params) do
    case SessionStore.set(fiber, session_id, params["agent"]) do
      {:ok, output} -> text(conn, 200, output)
      {:error, reason} -> text(conn, 400, reason)
    end
  end

  def create(conn, %{"action" => "clear", "fiber" => fiber}) do
    case SessionStore.clear(fiber) do
      {:ok, output} -> text(conn, 200, output)
      {:error, reason} -> text(conn, 400, reason)
    end
  end

  def create(conn, %{"action" => action}) do
    text(conn, 400, "unknown session action #{inspect(action)}")
  end

  def create(conn, _params), do: text(conn, 400, "missing required session fields")

  defp text(conn, status, output) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, output)
  end
end
