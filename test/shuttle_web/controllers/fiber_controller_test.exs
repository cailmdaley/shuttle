defmodule ShuttleWeb.FiberControllerTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ShuttleWeb.Endpoint

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "shuttle-fiber-controller-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    old_loom_home = System.get_env("LOOM_HOME")
    old_loom_homes = System.get_env("LOOM_HOMES")
    old_felt_stores_file = System.get_env("SHUTTLE_FELT_STORES_FILE")
    old_shuttle_host = System.get_env("SHUTTLE_HOST")

    System.put_env("LOOM_HOME", tmp)
    System.delete_env("LOOM_HOMES")
    System.put_env("SHUTTLE_FELT_STORES_FILE", Path.join(tmp, "felt_stores.json"))
    # Pin the daemon's identity for this test via the env var — the
    # Application config path is gone. Test assertions read `test-host`
    # back from the auto-stamped shuttle.host field.
    System.put_env("SHUTTLE_HOST", "test-host")

    on_exit(fn ->
      restore_env("LOOM_HOME", old_loom_home)
      restore_env("LOOM_HOMES", old_loom_homes)
      restore_env("SHUTTLE_FELT_STORES_FILE", old_felt_stores_file)
      restore_env("SHUTTLE_HOST", old_shuttle_host)

      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "POST /api/v1/fiber/create writes a daemon-local fiber with host default", %{tmp: tmp} do
    conn =
      api_conn()
      |> post(
        "/api/v1/fiber/create",
        Jason.encode!(%{
          id: "tests/create-me",
          name: "Create me",
          body: "hello\n",
          frontmatter: %{
            tags: ["constitution"],
            shuttle: %{
              enabled: true,
              kind: "oneshot",
              project_dir: tmp
            }
          }
        })
      )

    assert %{"id" => "tests/create-me", "path" => path} = Jason.decode!(conn.resp_body)
    assert conn.status == 200
    assert path == Path.join([tmp, ".felt", "tests", "create-me", "create-me.md"])

    assert {:ok,
            %{
              "name" => "Create me",
              "status" => "active",
              "shuttle" => %{"host" => "test-host", "project_dir" => ^tmp}
            }} =
             path
             |> File.read!()
             |> frontmatter()
             |> YamlElixir.read_from_string()
  end

  test "POST /api/v1/fiber/create writes under shuttle.project_dir when it differs from daemon root", %{
    tmp: tmp
  } do
    daemon_root = Path.join(tmp, "daemon-root")
    project_dir = Path.join(tmp, "project-dir")
    File.mkdir_p!(daemon_root)
    File.mkdir_p!(project_dir)
    System.put_env("LOOM_HOME", daemon_root)

    conn =
      api_conn()
      |> post(
        "/api/v1/fiber/create",
        Jason.encode!(%{
          id: "tests/project-local",
          name: "Project local",
          body: "hello\n",
          frontmatter: %{
            status: "open",
            shuttle: %{
              enabled: false,
              kind: "oneshot",
              project_dir: project_dir
            }
          }
        })
      )

    assert %{"id" => "tests/project-local", "path" => path} = Jason.decode!(conn.resp_body)
    assert conn.status == 200
    assert path == Path.join([project_dir, ".felt", "tests", "project-local", "project-local.md"])
    refute File.exists?(Path.join([daemon_root, ".felt", "tests", "project-local", "project-local.md"]))
    assert File.exists?(path)
  end

  test "POST /api/v1/fiber/create rejects enabled fibers without project_dir" do
    conn =
      api_conn()
      |> post(
        "/api/v1/fiber/create",
        Jason.encode!(%{
          id: "tests/missing-project",
          name: "Missing project",
          frontmatter: %{shuttle: %{enabled: true, kind: "oneshot"}}
        })
      )

    assert conn.status == 400

    assert %{"error" => "shuttle.project_dir is required when enabled=true"} =
             Jason.decode!(conn.resp_body)
  end

  test "POST /api/v1/fiber/create rejects cross-host blocks", %{tmp: tmp} do
    conn =
      api_conn()
      |> post(
        "/api/v1/fiber/create",
        Jason.encode!(%{
          id: "tests/wrong-host",
          name: "Wrong host",
          frontmatter: %{
            shuttle: %{enabled: true, kind: "oneshot", host: "candide", project_dir: tmp}
          }
        })
      )

    assert conn.status == 400
    assert %{"error" => error} = Jason.decode!(conn.resp_body)
    assert error =~ "does not match this daemon host"
  end

  defp api_conn do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp frontmatter(content) do
    [_, frontmatter | _] = String.split(content, "---\n", parts: 3)
    frontmatter
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
