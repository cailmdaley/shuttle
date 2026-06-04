defmodule ShuttleWeb.LifecycleControllerTest do
  use ExUnit.Case
  import Plug.Conn
  import Phoenix.ConnTest

  alias Shuttle.RuntimeStore

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

  test "accept for standing roles writes lifecycle store and evicts runtime frontmatter" do
    root =
      System.tmp_dir!()
      |> Path.join("shuttle-lifecycle-accept-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    runtime_store = Path.join(root, "runtime.db")
    fiber_dir = Path.join([store, ".felt", "tests", "standing-accept"])
    File.mkdir_p!(fiber_dir)
    path = Path.join(fiber_dir, "standing-accept.md")

    File.write!(path, """
    ---
    name: Standing accept
    status: closed
    outcome: digest
    tempered: false
    closed-at: 2026-06-01T09:30:00Z
    shuttle:
      enabled: true
      kind: standing
      host: #{Shuttle.Poller.own_host_id()}
      project_dir: #{store}
      schedule:
        expr: 0 9 * * 1-5
        tz: UTC
      review:
        state: awaiting
        run_id: run-1
        completed_at: 2026-06-01T09:12:00Z
        accepted_run_id: null
      next_due_at: 2026-06-01T09:00:00Z
      last_run_at: 2026-06-01T09:12:00Z
      session:
        id: stale-session
        dispatched_at: 2026-06-01T09:00:00Z
    ---

    Body.
    """)

    with_env(%{"LOOM_HOMES" => store, "SHUTTLE_RUNTIME_STORE" => runtime_store}, fn ->
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
      assert conn.resp_body =~ "accepted run run-1"

      text = File.read!(path)
      frontmatter = frontmatter(text)
      refute frontmatter =~ "review:"
      refute frontmatter =~ "next_due_at:"
      refute frontmatter =~ "last_run_at:"
      refute frontmatter =~ "session:"
      assert frontmatter =~ "status: active"
      assert frontmatter =~ ~s(outcome: "")
      assert frontmatter =~ "schedule:"

      assert [
               %{
                 fiber_id: "tests/standing-accept",
                 metadata: %{
                   phase: "scheduled",
                   run_id: "run-1",
                   next_due_at: next_due_at,
                   review: %{
                     "state" => "scheduled",
                     "run_id" => "run-1",
                     "accepted_run_id" => "run-1"
                   }
                 }
               }
             ] = RuntimeStore.list_lifecycle(runtime_store)

      # Regression for the next_due_at drift bug: accept must land on the next
      # occurrence AFTER now, not one cron tick from the STALE stored value. The
      # fixture's stored next_due_at (2026-06-01) is in the past; the old code
      # advanced it to 2026-06-02 — also in the past — so `due?` stayed true and
      # the role re-fired immediately (the morning-post drift). The fix anchors
      # on max(now, stored), so the result is a real future 09:00 tick.
      now = DateTime.utc_now()
      assert DateTime.compare(next_due_at, now) == :gt
      assert next_due_at.hour == 9 and next_due_at.minute == 0
    end)

    File.rm_rf(root)
  end

  test "accept re-enables a paused standing role (temper resumes it)" do
    root =
      System.tmp_dir!()
      |> Path.join("shuttle-lifecycle-accept-reenable-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    runtime_store = Path.join(root, "runtime.db")
    fiber_dir = Path.join([store, ".felt", "tests", "standing-accept-reenable"])
    File.mkdir_p!(fiber_dir)
    path = Path.join(fiber_dir, "standing-accept-reenable.md")

    # A role that was paused (enabled: false → Drafts) but whose last run's
    # awaiting review was preserved. Accepting it ("temper") should reschedule
    # AND flip enabled back on so it re-enters the queue.
    File.write!(path, """
    ---
    name: Standing accept reenable
    status: active
    shuttle:
      enabled: false
      kind: standing
      host: #{Shuttle.Poller.own_host_id()}
      project_dir: #{store}
      schedule:
        expr: 0 9 * * 1-5
        tz: UTC
      review:
        state: awaiting
        run_id: run-1
        completed_at: 2026-06-01T09:12:00Z
        accepted_run_id: null
      next_due_at: 2026-06-01T09:00:00Z
      last_run_at: 2026-06-01T09:12:00Z
    ---

    Body.
    """)

    with_env(%{"LOOM_HOMES" => store, "SHUTTLE_RUNTIME_STORE" => runtime_store}, fn ->
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
      assert frontmatter =~ "enabled: true"
      assert frontmatter =~ "status: active"
    end)

    File.rm_rf(root)
  end

  test "resume for standing roles writes immediate lifecycle store and evicts runtime frontmatter" do
    root =
      System.tmp_dir!()
      |> Path.join("shuttle-lifecycle-resume-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    runtime_store = Path.join(root, "runtime.db")
    fiber_dir = Path.join([store, ".felt", "tests", "standing-resume"])
    File.mkdir_p!(fiber_dir)
    path = Path.join(fiber_dir, "standing-resume.md")

    File.write!(path, """
    ---
    name: Standing resume
    status: active
    outcome: digest
    shuttle:
      enabled: true
      kind: standing
      host: #{Shuttle.Poller.own_host_id()}
      project_dir: #{store}
      schedule:
        expr: 0 9 * * 1-5
        tz: UTC
      review:
        state: awaiting
        run_id: run-2
      next_due_at: null
      last_run_at: 2026-06-01T09:12:00Z
    ---

    Body.
    """)

    with_env(%{"LOOM_HOMES" => store, "SHUTTLE_RUNTIME_STORE" => runtime_store}, fn ->
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
      refute frontmatter =~ "next_due_at:"
      refute frontmatter =~ "last_run_at:"
      assert frontmatter =~ "outcome: digest"

      assert [
               %{
                 fiber_id: "tests/standing-resume",
                 metadata: %{
                   phase: "scheduled",
                   run_id: "run-2",
                   next_due_at: %DateTime{},
                   review: %{"state" => "scheduled", "run_id" => "run-2"}
                 }
               }
             ] = RuntimeStore.list_lifecycle(runtime_store)
    end)

    File.rm_rf(root)
  end

  test "accept reads review and timing from lifecycle store after frontmatter eviction" do
    root =
      System.tmp_dir!()
      |> Path.join("shuttle-lifecycle-accept-overlay-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    runtime_store = Path.join(root, "runtime.db")
    fiber_dir = Path.join([store, ".felt", "tests", "standing-accept-overlay"])
    File.mkdir_p!(fiber_dir)
    path = Path.join(fiber_dir, "standing-accept-overlay.md")

    File.write!(path, """
    ---
    name: Standing accept overlay
    status: closed
    outcome: digest
    shuttle:
      enabled: true
      kind: standing
      host: #{Shuttle.Poller.own_host_id()}
      project_dir: #{store}
      schedule:
        expr: 0 9 * * 1-5
        tz: UTC
    ---

    Body.
    """)

    with_env(%{"LOOM_HOMES" => store, "SHUTTLE_RUNTIME_STORE" => runtime_store}, fn ->
      RuntimeStore.upsert_lifecycle(runtime_store, "tests/standing-accept-overlay", %{
        kind: "standing",
        phase: "awaiting",
        run_id: "run-overlay",
        next_due_at: ~U[2026-06-01 09:00:00Z],
        last_run_at: ~U[2026-06-01 09:12:00Z],
        review: %{
          "state" => "awaiting",
          "run_id" => "run-overlay",
          "completed_at" => "2026-06-01T09:12:00Z"
        }
      })

      conn =
        post(
          api_conn(),
          "/api/v1/lifecycle",
          Jason.encode!(%{
            "action" => "accept",
            "fiber" => "tests/standing-accept-overlay"
          })
        )

      assert conn.status == 200
      assert conn.resp_body =~ "accepted run run-overlay"

      frontmatter = path |> File.read!() |> frontmatter()
      refute frontmatter =~ "review:"
      refute frontmatter =~ "next_due_at:"
      refute frontmatter =~ "last_run_at:"

      assert [
               %{
                 metadata: %{
                   phase: "scheduled",
                   run_id: "run-overlay",
                   next_due_at: next_due_at,
                   last_run_at: ~U[2026-06-01 09:12:00Z],
                   review: %{
                     "state" => "scheduled",
                     "run_id" => "run-overlay",
                     "accepted_run_id" => "run-overlay"
                   }
                 }
               }
             ] = RuntimeStore.list_lifecycle(runtime_store)

      # Regression for the next_due_at drift bug: accept must land on the next
      # occurrence AFTER now, not one cron tick from the STALE stored value. The
      # fixture's stored next_due_at (2026-06-01) is in the past; the old code
      # advanced it to 2026-06-02 — also in the past — so `due?` stayed true and
      # the role re-fired immediately (the morning-post drift). The fix anchors
      # on max(now, stored), so the result is a real future 09:00 tick.
      now = DateTime.utc_now()
      assert DateTime.compare(next_due_at, now) == :gt
      assert next_due_at.hour == 9 and next_due_at.minute == 0
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
      assert conn.resp_body =~ "fiber has no review state"
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
