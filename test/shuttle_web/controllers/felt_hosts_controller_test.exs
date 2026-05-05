defmodule ShuttleWeb.FeltHostsControllerTest do
  use ExUnit.Case
  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint ShuttleWeb.Endpoint

  setup do
    original = System.get_env("SHUTTLE_FELT_HOSTS_FILE")
    path = Path.join(System.tmp_dir!(), "shuttle-felt-hosts-controller-#{System.unique_integer([:positive])}.json")
    System.put_env("SHUTTLE_FELT_HOSTS_FILE", path)

    on_exit(fn ->
      File.rm(path)

      case original do
        nil -> System.delete_env("SHUTTLE_FELT_HOSTS_FILE")
        value -> System.put_env("SHUTTLE_FELT_HOSTS_FILE", value)
      end
    end)

    :ok
  end

  defp api_conn do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  test "persists normalized felt hosts" do
    conn =
      post(
        api_conn(),
        "/api/v1/felt-hosts",
        Jason.encode!(%{"felt_hosts" => ["~/loom", "/tmp/project", "~/loom", "  "]})
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
    assert body["felt_hosts"] == [Path.expand("~/loom"), "/tmp/project"]

    {:ok, persisted} = File.read(Path.expand(System.get_env("SHUTTLE_FELT_HOSTS_FILE")))
    decoded = Jason.decode!(persisted)
    assert decoded["felt_hosts"] == [Path.expand("~/loom"), "/tmp/project"]
    assert decoded["version"] == 1
  end

  test "empty list clears the persisted file" do
    path = Path.expand(System.get_env("SHUTTLE_FELT_HOSTS_FILE"))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"version" => 1, "felt_hosts" => ["/tmp/stale"]}))

    conn = post(api_conn(), "/api/v1/felt-hosts", Jason.encode!(%{"felt_hosts" => []}))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["felt_hosts"] == []
    refute File.exists?(path)
  end

  test "rejects malformed payloads" do
    conn = post(api_conn(), "/api/v1/felt-hosts", Jason.encode!(%{"felt_hosts" => "~/loom"}))

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] =~ "felt_hosts"
  end
end
