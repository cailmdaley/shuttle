defmodule ShuttleWeb.LifecycleControllerTest do
  use ExUnit.Case
  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint ShuttleWeb.Endpoint

  # Interactivity is retired: install never forwards --interactive, even if a
  # stale client still posts the key. The flag is silently dropped, not relayed.
  test "install drops a stale interactive key rather than forwarding it" do
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
             "install\ntests/interactive\n--project-dir\n/tmp/project\n"
  end

  # set-interactive is retired: the controller no longer allows the action, so a
  # stale client gets a clean rejection rather than a shuttle-ctl invocation.
  test "set-interactive is rejected as an unknown lifecycle action" do
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

    assert conn.status == 400
    assert conn.resp_body =~ "unknown lifecycle action"
  end

  test "set-outcome delegates to shuttle-ctl, preserving a multi-line value as one arg" do
    root =
      System.tmp_dir!()
      |> Path.join("shuttle-lifecycle-outcome-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    fiber_dir = Path.join([store, ".felt", "tests", "outcome-edit"])
    File.mkdir_p!(fiber_dir)
    File.write!(Path.join(fiber_dir, "outcome-edit.md"), "---\nname: Outcome edit\n---\n\n")

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
          "action" => "set-outcome",
          "fiber" => "tests/outcome-edit",
          "outcome" => "Blocked: waiting on ADS token\nsecond line"
        })
      )

    assert conn.status == 200

    # The multi-line outcome rides as a single argv element (one `--outcome`
    # value), so the block scalar survives without stdin piping.
    assert File.read!(args_file) ==
             "set-outcome\ntests/outcome-edit\n--outcome\nBlocked: waiting on ADS token\nsecond line\n"
  end

  test "accept for standing roles re-arms from the doc and evicts runtime frontmatter" do
    root =
      System.tmp_dir!()
      |> Path.join("shuttle-lifecycle-accept-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    fiber_dir = Path.join([store, ".felt", "tests", "standing-accept"])
    File.mkdir_p!(fiber_dir)
    path = Path.join(fiber_dir, "standing-accept.md")

    # Awaiting is the document itself — `status: closed` + untempered. accept
    # re-arms straight from the doc schedule; there is no `review` axis and no
    # runtime row (slice 6: runtime store gone). next_due is recomputed from the
    # cron schedule on the next poll.
    File.write!(path, """
    ---
    name: Standing accept
    status: closed
    outcome: digest
    closed-at: 2026-06-01T09:30:00Z
    shuttle:
      kind: standing
      host: #{Shuttle.Poller.own_host_id()}
      project_dir: #{store}
      schedule:
        expr: 0 9 * * 1-5
        tz: UTC
    ---

    Body.
    """)

    with_env(%{"LOOM_HOMES" => store}, fn ->
      conn =
        post(
          api_conn(),
          "/api/v1/lifecycle",
          Jason.encode!(%{
            "action" => "accept",
            "fiber" => "tests/standing-accept"
          })
        )

      assert conn.status == 200
      assert conn.resp_body =~ "accepted run for tests/standing-accept"
      # accept re-arms to the next occurrence AFTER now (cron.next(now)) — the
      # message carries the computed future tick.
      assert conn.resp_body =~ "next due:"

      text = File.read!(path)
      frontmatter = frontmatter(text)
      refute frontmatter =~ "review:"
      refute frontmatter =~ "closed-at:"
      assert frontmatter =~ "status: active"
      assert frontmatter =~ ~s(outcome: "")
      assert frontmatter =~ "schedule:"
    end)

    File.rm_rf(root)
  end

  test "accept re-arms a standing role awaiting review (temper resumes it)" do
    root =
      System.tmp_dir!()
      |> Path.join("shuttle-lifecycle-accept-reenable-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    fiber_dir = Path.join([store, ".felt", "tests", "standing-accept-reenable"])
    File.mkdir_p!(fiber_dir)
    path = Path.join(fiber_dir, "standing-accept-reenable.md")

    # A standing role whose last run is awaiting (status: closed + untempered).
    # Accepting it ("temper") re-arms from the doc schedule — status: active is
    # the sole dispatch gate (slice 5: no enabled flag), and any stale enabled
    # key is wiped on the rewrite.
    File.write!(path, """
    ---
    name: Standing accept reenable
    status: closed
    closed-at: 2026-06-01T09:30:00Z
    shuttle:
      enabled: false
      kind: standing
      host: #{Shuttle.Poller.own_host_id()}
      project_dir: #{store}
      schedule:
        expr: 0 9 * * 1-5
        tz: UTC
    ---

    Body.
    """)

    with_env(%{"LOOM_HOMES" => store}, fn ->
      conn =
        post(
          api_conn(),
          "/api/v1/lifecycle",
          Jason.encode!(%{
            "action" => "accept",
            "fiber" => "tests/standing-accept-reenable"
          })
        )

      assert conn.status == 200

      frontmatter = frontmatter(File.read!(path))
      assert frontmatter =~ "status: active"
      # Clean cutover: no enabled flag survives the re-arm rewrite.
      refute frontmatter =~ "enabled"
    end)

    File.rm_rf(root)
  end

  test "resume for standing roles re-arms from the doc and evicts runtime frontmatter" do
    root =
      System.tmp_dir!()
      |> Path.join("shuttle-lifecycle-resume-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    fiber_dir = Path.join([store, ".felt", "tests", "standing-resume"])
    File.mkdir_p!(fiber_dir)
    path = Path.join(fiber_dir, "standing-resume.md")

    # Awaiting is `status: closed` + untempered. resume re-arms from the doc for
    # immediate dispatch — no review axis, no runtime row (slice 6).
    File.write!(path, """
    ---
    name: Standing resume
    status: closed
    outcome: digest
    closed-at: 2026-06-01T09:12:00Z
    shuttle:
      kind: standing
      host: #{Shuttle.Poller.own_host_id()}
      project_dir: #{store}
      schedule:
        expr: 0 9 * * 1-5
        tz: UTC
    ---

    Body.
    """)

    with_env(%{"LOOM_HOMES" => store}, fn ->
      conn =
        post(
          api_conn(),
          "/api/v1/lifecycle",
          Jason.encode!(%{
            "action" => "resume",
            "fiber" => "tests/standing-resume"
          })
        )

      assert conn.status == 200
      assert conn.resp_body =~ "re-queued for immediate dispatch"

      frontmatter = path |> File.read!() |> frontmatter()
      refute frontmatter =~ "review:"
      refute frontmatter =~ "closed-at:"
      assert frontmatter =~ "status: active"
      assert frontmatter =~ "outcome: digest"
    end)

    File.rm_rf(root)
  end

  test "accept refuses a status:active role (armed is not awaiting)" do
    # Accept reads ONLY the document (slice 4 deleted the review overlay, slice 6
    # the runtime store): an armed (`status: active`) role is not awaiting, so
    # accept refuses. This pins that no path revives a transition from anything
    # but the document's status + tempered.
    root =
      System.tmp_dir!()
      |> Path.join("shuttle-lifecycle-accept-armed-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    fiber_dir = Path.join([store, ".felt", "tests", "standing-accept-armed"])
    File.mkdir_p!(fiber_dir)
    path = Path.join(fiber_dir, "standing-accept-armed.md")

    File.write!(path, """
    ---
    name: Standing accept armed
    status: active
    outcome: digest
    shuttle:
      kind: standing
      host: #{Shuttle.Poller.own_host_id()}
      project_dir: #{store}
      schedule:
        expr: 0 9 * * 1-5
        tz: UTC
    ---

    Body.
    """)

    with_env(%{"LOOM_HOMES" => store}, fn ->
      conn =
        post(
          api_conn(),
          "/api/v1/lifecycle",
          Jason.encode!(%{
            "action" => "accept",
            "fiber" => "tests/standing-accept-armed"
          })
        )

      assert conn.status == 400
      assert conn.resp_body =~ "not awaiting review"

      # The document is untouched — still armed.
      assert frontmatter(File.read!(path)) =~ "status: active"
    end)

    File.rm_rf(root)
  end

  test "accept fails closed instead of falling back to shuttle-ctl frontmatter writes" do
    args_file = install_fake_shuttle_ctl!()

    root =
      System.tmp_dir!()
      |> Path.join("shuttle-lifecycle-accept-fail-closed-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    fiber_dir = Path.join([store, ".felt", "tests", "standing-accept-fail"])
    File.mkdir_p!(fiber_dir)

    File.write!(Path.join(fiber_dir, "standing-accept-fail.md"), """
    ---
    name: Standing accept fail
    status: active
    shuttle:
      enabled: true
      kind: standing
      schedule:
        expr: 0 9 * * 1-5
        tz: UTC
    ---

    Body.
    """)

    with_env(%{"LOOM_HOMES" => store}, fn ->
      conn =
        post(
          api_conn(),
          "/api/v1/lifecycle",
          Jason.encode!(%{
            "action" => "accept",
            "fiber" => "tests/standing-accept-fail"
          })
        )

      assert conn.status == 400
      assert conn.resp_body =~ "not awaiting review"
      refute File.exists?(args_file)
    end)

    File.rm_rf(root)
  end

  defp api_conn do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
  end

  defp frontmatter(content) do
    [_, frontmatter | _] = String.split(content, "---\n", parts: 3)
    frontmatter
  end

  defp with_env(vars, fun) do
    old = Map.new(vars, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)

    try do
      fun.()
    after
      Enum.each(old, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
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
