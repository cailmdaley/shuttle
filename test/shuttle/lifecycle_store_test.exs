defmodule Shuttle.LifecycleStoreTest do
  use ExUnit.Case

  alias Shuttle.{Actions, LifecycleStore, RuntimeStore}

  describe "reset_review/1" do
    test "deletes the runtime lifecycle row so the poll overlay can't re-inject stale awaiting" do
      # The durable root of the un-temper re-compost bug: close/reopen wrote only
      # frontmatter and never touched the runtime store, so a standing role's
      # `review.state: awaiting` survived in the runtime DB indefinitely. The
      # poll-path merge_lifecycle_overlay (frontmatter-precedence put_if_missing)
      # then re-injected it on reopen for any role lacking a frontmatter review
      # key — re-opening the verdict-drop window. reset_review revives
      # RuntimeStore.delete_lifecycle (previously zero production callers) to
      # clear that row.
      with_runtime_store(fn path ->
        RuntimeStore.upsert_lifecycle(path, "tests/standing", %{
          kind: "standing",
          phase: "scheduled",
          run_id: "run-1"
        })

        assert RuntimeStore.fetch_lifecycle(path, "tests/standing") != nil

        assert {:ok, message} = LifecycleStore.reset_review("tests/standing")
        assert message =~ "reset review lifecycle for tests/standing"
        assert message =~ "cleared runtime row"

        # Row gone → nothing for any reader to revive. This is the "survives a
        # poll" guarantee: the stale row cannot reappear because its only source
        # has been removed.
        assert RuntimeStore.fetch_lifecycle(path, "tests/standing") == nil
        assert RuntimeStore.list_lifecycle(path) == []
      end)
    end

    test "is a no-op for a fiber with no runtime row (oneshots, already-clean roles)" do
      with_runtime_store(fn path ->
        assert {:ok, message} = LifecycleStore.reset_review("tests/clean")
        assert message =~ "reset review lifecycle for tests/clean"
        refute message =~ "cleared runtime row"
        assert RuntimeStore.fetch_lifecycle(path, "tests/clean") == nil
      end)
    end
  end

  describe "the closed/reopen review reset closes the un-temper re-compost loop" do
    test "after reset, an awaiting-review drag on the reopened role resolves to close-awaiting-review" do
      # End-to-end semantic pin tying the two halves together. After close/reopen
      # reset review to scheduled (frontmatter) and cleared the runtime row, the
      # reopened standing role is active + scheduled (NOT awaiting). Resolving the
      # awaitingReview drag on THAT state returns close-awaiting-review — the card
      # lands back in the review pile — instead of close-composted, the silent
      # re-compost. Without the reset, the role would still read awaiting and
      # re-compost (the bug). This is the contract the reset exists to protect.
      reopened_after_reset = %{
        "id" => "tests/standing",
        "status" => "active",
        "shuttle" => %{
          "enabled" => true,
          "kind" => "standing",
          "review" => %{"state" => "scheduled"}
        }
      }

      assert {:ok, %{id: "close-awaiting-review"}} =
               Actions.resolve_transition(reopened_after_reset, "awaitingReview")

      # And the pre-reset state it replaces would have re-composted — the exact
      # regression. (Documents the delta the reset removes.)
      stale_awaiting = put_in(reopened_after_reset, ["shuttle", "review", "state"], "awaiting")

      assert {:ok, %{id: "close-awaiting-review"}} =
               Actions.resolve_transition(stale_awaiting, "awaitingReview"),
             "post-C4-fix, even a stale awaiting role no longer re-composts on the home column"
    end
  end

  describe "accept/resume recognize new-model awaiting (status:closed + untempered)" do
    test "accept re-arms a closed+untempered standing role from the doc schedule" do
      with_doc_awaiting_role(fn fiber_id, path ->
        assert {:ok, message} = LifecycleStore.accept(fiber_id)
        assert message =~ "accepted run for #{fiber_id}"
        assert message =~ "next due:"

        # Document re-armed straight from the doc: status:active, verdict cleared.
        fm = read_frontmatter(path)
        assert fm["status"] == "active"
        refute Map.has_key?(fm, "tempered")

        # A scheduled runtime row exists with a FUTURE next_due (cron.next(now)),
        # not the past — the morning-post-drift anchor-on-now rule.
        row = RuntimeStore.fetch_lifecycle(runtime_store_path(), fiber_id)
        assert row.phase == "scheduled"
        assert %DateTime{} = row.next_due_at
        assert DateTime.compare(row.next_due_at, DateTime.utc_now()) == :gt
      end)
    end

    test "resume re-arms a closed+untempered standing role to immediate" do
      with_doc_awaiting_role(fn fiber_id, path ->
        assert {:ok, message} = LifecycleStore.resume(fiber_id)
        assert message =~ "re-queued for immediate dispatch"

        fm = read_frontmatter(path)
        assert fm["status"] == "active"
        refute Map.has_key?(fm, "tempered")

        row = RuntimeStore.fetch_lifecycle(runtime_store_path(), fiber_id)
        assert row.phase == "scheduled"
        # Immediate: next_due is ~now (resume re-queues right away).
        assert %DateTime{} = row.next_due_at
        assert DateTime.diff(DateTime.utc_now(), row.next_due_at) |> abs() < 5
      end)
    end

    test "a tempered:false (composted) standing role is NOT awaiting — accept refuses" do
      with_doc_awaiting_role(
        fn fiber_id, _path ->
          # Composted is a verdict, not awaiting: it has no runtime review row,
          # so the legacy review path is consulted and rejects.
          assert {:error, reason} = LifecycleStore.accept(fiber_id)
          assert reason =~ "review"
        end,
        status: "closed",
        tempered: false
      )
    end
  end

  describe "mark_awaiting/1 — the standing-exit writer (active → closed, untempered)" do
    test "flips status:active → closed with closed-at, no verdict, and reads as doc-awaiting" do
      with_doc_awaiting_role(
        fn fiber_id, path ->
          assert {:ok, message} = LifecycleStore.mark_awaiting(fiber_id)
          assert message =~ "awaiting review"

          fm = read_frontmatter(path)
          assert fm["status"] == "closed"
          assert is_binary(fm["closed-at"])
          refute Map.has_key?(fm, "tempered")
        end,
        status: "active"
      )
    end

    test "the full exit → accept cycle re-arms the role straight from the document" do
      with_doc_awaiting_role(
        fn fiber_id, path ->
          # Worker exits → awaiting review (status:closed, untempered).
          assert {:ok, _} = LifecycleStore.mark_awaiting(fiber_id)
          assert read_frontmatter(path)["status"] == "closed"

          # Human accepts → re-armed from the doc schedule (status:active, verdict
          # and closed-at cleared). The active → closed → active cycle is real.
          assert {:ok, _} = LifecycleStore.accept(fiber_id)
          fm = read_frontmatter(path)
          assert fm["status"] == "active"
          refute Map.has_key?(fm, "tempered")
          refute Map.has_key?(fm, "closed-at")
        end,
        status: "active"
      )
    end
  end

  # Builds a real on-disk felt fiber (resolvable by the felt CLI) in the
  # new-model awaiting shape, points LOOM_HOMES + SHUTTLE_RUNTIME_STORE at the
  # fixtures, and runs `fun.(fiber_id, path)`.
  defp with_doc_awaiting_role(fun, opts \\ []) do
    status = Keyword.get(opts, :status, "closed")
    tempered = Keyword.get(opts, :tempered, nil)

    loom = Path.join(System.tmp_dir!(), "shuttle-lifecycle-doc-test-#{System.unique_integer([:positive])}")
    felt_dir = Path.join([loom, ".felt", "life", "french", "practice"])
    File.mkdir_p!(felt_dir)
    path = Path.join(felt_dir, "practice.md")

    tempered_line = if is_nil(tempered), do: "", else: "tempered: #{tempered}\n"

    File.write!(path, """
    ---
    name: Daily French practice
    status: #{status}
    #{tempered_line}shuttle:
      enabled: true
      kind: standing
      host: testhost
      agent: claude-sonnet
      schedule:
        expr: "0 8 * * *"
        tz: Europe/Paris
    ---

    Body.
    """)

    runtime = Path.join(loom, "runtime.db")

    prev_loom = System.get_env("LOOM_HOMES")
    prev_runtime = System.get_env("SHUTTLE_RUNTIME_STORE")
    System.put_env("LOOM_HOMES", loom)
    System.put_env("SHUTTLE_RUNTIME_STORE", runtime)
    RuntimeStore.init(runtime)

    try do
      fun.("life/french/practice", path)
    after
      restore_env("LOOM_HOMES", prev_loom)
      restore_env("SHUTTLE_RUNTIME_STORE", prev_runtime)
      File.rm_rf(loom)
    end
  end

  defp read_frontmatter(path) do
    [_, fm, _] = File.read!(path) |> String.split("---", parts: 3)
    YamlElixir.read_from_string!(fm)
  end

  defp runtime_store_path, do: System.get_env("SHUTTLE_RUNTIME_STORE")

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp with_runtime_store(fun) do
    path =
      Path.join(
        System.tmp_dir!(),
        "shuttle-lifecycle-store-test-#{System.unique_integer([:positive])}/runtime.db"
      )

    old = System.get_env("SHUTTLE_RUNTIME_STORE")
    System.put_env("SHUTTLE_RUNTIME_STORE", path)
    RuntimeStore.init(path)

    try do
      fun.(path)
    after
      if old, do: System.put_env("SHUTTLE_RUNTIME_STORE", old), else: System.delete_env("SHUTTLE_RUNTIME_STORE")
      File.rm_rf(Path.dirname(path))
    end
  end
end
