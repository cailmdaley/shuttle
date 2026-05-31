defmodule ShuttleWeb.FeltHistoryControllerTest do
  use ExUnit.Case
  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint ShuttleWeb.Endpoint

  test "appends typed history against the configured felt store that owns the fiber" do
    root =
      System.tmp_dir!()
      |> Path.join("shuttle-felt-history-controller-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    fiber_dir = Path.join([store, ".felt", "tests", "remote-directive"])
    File.mkdir_p!(fiber_dir)

    File.write!(
      Path.join(fiber_dir, "remote-directive.md"),
      "---\nname: Remote directive\nstatus: active\n---\n\nbody\n"
    )

    args_file = install_fake_felt!(root)
    old_loom_homes = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", store)

    on_exit(fn ->
      restore_env("LOOM_HOMES", old_loom_homes)
      File.rm_rf(root)
    end)

    conn =
      post(
        api_conn(),
        "/api/v1/felt-history",
        Jason.encode!(%{
          "fiber_id" => "tests/remote-directive",
          "kind" => "review-comment",
          "summary" => "keep the directive on the remote loom",
          "fields" => %{"resume_mode" => "fresh"}
        })
      )

    assert conn.status == 200

    assert File.read!(args_file) ==
             "-C\n#{store}\nhistory\nappend\ntests/remote-directive\n--kind\nreview-comment\n--summary\nkeep the directive on the remote loom\n--field\nresume_mode=fresh\n"
  end

  defp api_conn do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
  end

  defp install_fake_felt!(root) do
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)

    bin = Path.join(bin_dir, "felt")
    args_file = Path.join(root, "felt-args")

    File.write!(bin, """
    #!/bin/sh
    printf '%s\\n' "$@" > "$FELT_ARGS_FILE"
    printf 'ok\\n'
    """)

    File.chmod!(bin, 0o755)

    old_path = System.get_env("PATH")
    old_args_file = System.get_env("FELT_ARGS_FILE")

    System.put_env("PATH", bin_dir <> ":" <> (old_path || ""))
    System.put_env("FELT_ARGS_FILE", args_file)

    on_exit(fn ->
      restore_env("PATH", old_path)
      restore_env("FELT_ARGS_FILE", old_args_file)
    end)

    args_file
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
