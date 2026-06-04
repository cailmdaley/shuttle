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
          phase: "awaiting",
          run_id: "run-1",
          review: %{"state" => "awaiting", "run_id" => "run-1"}
        })

        assert RuntimeStore.fetch_lifecycle(path, "tests/standing") != nil

        assert {:ok, message} = LifecycleStore.reset_review("tests/standing")
        assert message =~ "reset review lifecycle for tests/standing"
        assert message =~ "was awaiting"

        # Row gone → the overlay has nothing to merge → a subsequent poll cannot
        # re-inject awaiting. This is the "survives a poll" guarantee: the stale
        # state cannot reappear because its only source has been removed.
        assert RuntimeStore.fetch_lifecycle(path, "tests/standing") == nil
        assert RuntimeStore.list_lifecycle(path) == []
      end)
    end

    test "is a no-op for a fiber with no runtime row (oneshots, already-clean roles)" do
      with_runtime_store(fn path ->
        assert {:ok, message} = LifecycleStore.reset_review("tests/clean")
        assert message =~ "reset review lifecycle for tests/clean"
        refute message =~ "was "
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
