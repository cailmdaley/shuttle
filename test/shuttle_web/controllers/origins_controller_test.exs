defmodule ShuttleWeb.OriginsControllerTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest

  @endpoint ShuttleWeb.Endpoint

  setup do
    previous = Application.get_env(:shuttle, :remotes, [])

    on_exit(fn ->
      Application.put_env(:shuttle, :remotes, previous)
    end)

    :ok
  end

  test "GET /api/v1/origins returns local plus configured remotes" do
    Application.put_env(:shuttle, :remotes, [
      %{name: "candide", url: "http://127.0.0.1:4001"}
    ])

    conn =
      build_conn()
      |> get("/api/v1/origins")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert Enum.any?(
             body["origins"],
             &match?(%{"name" => "local", "url" => "http://127.0.0.1:" <> _}, &1)
           )

    assert %{"name" => "candide", "url" => "http://127.0.0.1:4001"} in body["origins"]
  end
end
