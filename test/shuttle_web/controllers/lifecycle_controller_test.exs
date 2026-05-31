defmodule ShuttleWeb.LifecycleControllerTest do
  use ExUnit.Case
  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint ShuttleWeb.Endpoint

  test "install forwards interactive through shuttle-ctl" do
    args_file = install_fake_shuttle_ctl!()

    conn =
      post(
        api_conn(),
        "/api/v1/lifecycle",
        Jason.encode!(%{
          "action" => "install",
          "fiber" => "tests/interactive",
          "project_dir" => "/tmp/project",
          "interactive" => true
        })
      )

    assert conn.status == 200

    assert File.read!(args_file) ==
             "install\ntests/interactive\n--project-dir\n/tmp/project\n--interactive\n"
  end

  test "set-interactive delegates to shuttle-ctl" do
    root =
      System.tmp_dir!()
      |> Path.join("shuttle-lifecycle-store-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    fiber_dir = Path.join([store, ".felt", "tests", "interactive"])
    File.mkdir_p!(fiber_dir)
    File.write!(Path.join(fiber_dir, "interactive.md"), "---\nname: Interactive\n---\n\n")

    args_file = install_fake_shuttle_ctl!()
    old_loom_homes = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", store)

    on_exit(fn ->
      restore_env("LOOM_HOMES", old_loom_homes)
      File.rm_rf(root)
    end)

    conn =
      post(
        api_conn(),
        "/api/v1/lifecycle",
        Jason.encode!(%{
          "action" => "set-interactive",
          "fiber" => "tests/interactive",
          "interactive" => false
        })
      )

    assert conn.status == 200

    assert File.read!(args_file) ==
             "--felt-store\n#{store}\nset-interactive\ntests/interactive\nfalse\n"
  end

  defp api_conn do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
  end

  defp install_fake_shuttle_ctl! do
    dir =
      System.tmp_dir!()
      |> Path.join("shuttle-lifecycle-controller-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    bin = Path.join(dir, "shuttle-ctl")
    args_file = Path.join(dir, "args")

    File.write!(bin, """
    #!/bin/sh
    printf '%s\\n' "$@" > "$SHUTTLE_CTL_ARGS_FILE"
    printf 'ok\\n'
    """)

    File.chmod!(bin, 0o755)

    old_path = System.get_env("PATH")
    old_args_file = System.get_env("SHUTTLE_CTL_ARGS_FILE")

    System.put_env("PATH", dir <> ":" <> (old_path || ""))
    System.put_env("SHUTTLE_CTL_ARGS_FILE", args_file)

    on_exit(fn ->
      restore_env("PATH", old_path)
      restore_env("SHUTTLE_CTL_ARGS_FILE", old_args_file)
      File.rm_rf(dir)
    end)

    args_file
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
