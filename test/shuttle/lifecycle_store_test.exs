defmodule Shuttle.LifecycleStoreTest do
  use ExUnit.Case

  alias Shuttle.LifecycleStore

  describe "accept/resume recognize new-model awaiting (status:closed + untempered)" do
    test "accept re-arms a closed+untempered standing role from the doc schedule" do
      with_doc_awaiting_role(fn fiber_id, path ->
        assert {:ok, message} = LifecycleStore.accept(fiber_id)
        assert message =~ "accepted run for #{fiber_id}"
        assert message =~ "next due:"

        # Document re-armed straight from the doc: status:active, verdict cleared.
        # next_due is recomputed from the cron schedule on the next poll — there
        # is no runtime row to assert (slice 6: runtime store gone).
        fm = read_frontmatter(path)
        assert fm["status"] == "active"
        refute Map.has_key?(fm, "tempered")
        refute Map.has_key?(fm, "closed-at")
      end)
    end

    test "resume re-arms a closed+untempered standing role to immediate" do
      with_doc_awaiting_role(fn fiber_id, path ->
        assert {:ok, message} = LifecycleStore.resume(fiber_id)
        assert message =~ "re-queued for immediate dispatch"

        fm = read_frontmatter(path)
        assert fm["status"] == "active"
        refute Map.has_key?(fm, "tempered")
      end)
    end

    test "a tempered:false (composted) standing role is NOT awaiting — accept refuses" do
      with_doc_awaiting_role(
        fn fiber_id, _path ->
          # Composted is a verdict, not awaiting (status:closed + tempered:false):
          # the doc-awaiting precondition rejects.
          assert {:error, reason} = LifecycleStore.accept(fiber_id)
          assert reason =~ "not acceptable"
        end,
        status: "closed",
        tempered: false
      )
    end

    test "accept re-arms an active+untempered standing role (temper mid-run / pre-exit-mark)" do
      # The morning-post temper bug: Temper clicked while the run was still
      # status:active (worker alive or just killed, exit writer not yet run).
      # Accept must re-arm idempotently rather than refuse — the refusal is
      # what let the transition fall through to close-tempered.
      with_doc_awaiting_role(
        fn fiber_id, path ->
          assert {:ok, message} = LifecycleStore.accept(fiber_id)
          assert message =~ "accepted run for #{fiber_id}"

          fm = read_frontmatter(path)
          assert fm["status"] == "active"
          refute Map.has_key?(fm, "tempered")
        end,
        status: "active"
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

  describe "pinned roles are not cyclical (Option D: loop while active, park at open)" do
    test "accept and mark_awaiting reject a pinned role (standing-only)" do
      # Pinned is no longer cyclical (Option D): a pinned run does not close to
      # awaiting-review and there is no accept/re-arm cycle. mark_awaiting (the
      # standing worker-exit closer) and accept (the standing recurrence-advance)
      # both reject a pinned block by KIND — even in the awaiting-shaped
      # status:closed + untempered state a standing role would accept from.
      with_pinned_role(
        fn fiber_id, path ->
          assert {:error, msg} = LifecycleStore.mark_awaiting(fiber_id)
          assert msg =~ "standing"
          # Untouched: mark_awaiting did not close it.
          assert read_frontmatter(path)["status"] == "closed"

          assert {:error, accept_msg} = LifecycleStore.accept(fiber_id)
          assert accept_msg =~ "standing"
        end,
        status: "closed"
      )
    end

    test "rearm starts a parked pinned role (open → active) for force-dispatch" do
      # The board's strip → In-flight "start" gesture force-dispatches a parked
      # (status:open) pinned role; maybe_force_rearm → rearm writes open → active
      # so the role both spawns now AND keeps looping. rearm covers pinned because
      # a pinned role is perennial (its active state re-dispatches).
      with_pinned_role(
        fn fiber_id, path ->
          assert read_frontmatter(path)["status"] == "open"
          assert {:ok, message} = LifecycleStore.rearm(fiber_id)
          assert message =~ "re-armed"
          assert read_frontmatter(path)["status"] == "active"
        end,
        status: "open"
      )
    end
  end

  # Builds a real on-disk felt fiber (resolvable by the felt CLI) in the
  # new-model awaiting shape, points LOOM_HOMES at the fixture, and runs
  # `fun.(fiber_id, path)`. There is no runtime store anymore (slice 6): the
  # felt document carries the entire lifecycle.
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
      kind: standing
      host: testhost
      agent: claude-sonnet
      schedule:
        expr: "0 8 * * *"
        tz: Europe/Paris
    ---

    Body.
    """)

    prev_loom = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", loom)

    try do
      fun.("life/french/practice", path)
    after
      restore_env("LOOM_HOMES", prev_loom)
      File.rm_rf(loom)
    end
  end

  # Pinned variant of with_doc_awaiting_role: a schedule-less pinned block. The
  # pinned role's parked rest state is status:open on the strip (Option D);
  # status:active is the looping state.
  defp with_pinned_role(fun, opts) do
    status = Keyword.get(opts, :status, "open")
    tempered = Keyword.get(opts, :tempered, nil)

    loom = Path.join(System.tmp_dir!(), "shuttle-lifecycle-pin-test-#{System.unique_integer([:positive])}")
    felt_dir = Path.join([loom, ".felt", "ai-futures", "tokenmaxxing", "operator"])
    File.mkdir_p!(felt_dir)
    path = Path.join(felt_dir, "operator.md")

    tempered_line = if is_nil(tempered), do: "", else: "tempered: #{tempered}\n"

    File.write!(path, """
    ---
    name: Operator
    status: #{status}
    #{tempered_line}shuttle:
      kind: pinned
      host: testhost
      agent: claude-opus
    ---

    Body.
    """)

    prev_loom = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", loom)

    try do
      fun.("ai-futures/tokenmaxxing/operator", path)
    after
      restore_env("LOOM_HOMES", prev_loom)
      File.rm_rf(loom)
    end
  end

  defp read_frontmatter(path) do
    [_, fm, _] = File.read!(path) |> String.split("---", parts: 3)
    YamlElixir.read_from_string!(fm)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
