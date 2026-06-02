defmodule Shuttle.RuntimeStoreTest do
  use ExUnit.Case

  alias Shuttle.RuntimeStore

  test "round-trips running worker metadata through sqlite" do
    path = temp_db_path()
    now = DateTime.utc_now()

    RuntimeStore.upsert_running(path, "tests/runtime", %{
      session: "runtime-shuttle",
      agent_id: "codex",
      state: "running",
      run_id: "run-123",
      run_kind: "ad_hoc",
      started_at: now,
      last_activity_at: now
    })

    assert [
             %{
               fiber_id: "tests/runtime",
               metadata: %{
                 session: "runtime-shuttle",
                 agent_id: "codex",
                 state: "running",
                 run_id: "run-123",
                 run_kind: "ad_hoc",
                 started_at: %DateTime{},
                 last_activity_at: %DateTime{}
               }
             }
           ] = RuntimeStore.list_running(path)

    RuntimeStore.delete_running(path, "tests/runtime")
    assert [] = RuntimeStore.list_running(path)
  after
    System.tmp_dir!()
    |> Path.join("shuttle-runtime-store-test-*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)
  end

  test "round-trips retry metadata through sqlite" do
    path = temp_db_path()
    due_at_ms = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    RuntimeStore.upsert_retry(path, "tests/retry", %{
      attempt: 2,
      due_at_ms: due_at_ms,
      error: "worker exited",
      delay_type: :continuation
    })

    assert [
             %{
               fiber_id: "tests/retry",
               metadata: %{
                 attempt: 2,
                 due_at_ms: ^due_at_ms,
                 error: "worker exited",
                 delay_type: :continuation
               }
             }
           ] = RuntimeStore.list_retries(path)

    RuntimeStore.delete_retry(path, "tests/retry")
    assert [] = RuntimeStore.list_retries(path)
  after
    System.tmp_dir!()
    |> Path.join("shuttle-runtime-store-test-*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)
  end

  test "round-trips lifecycle metadata through sqlite" do
    path = temp_db_path()
    next_due_at = ~U[2026-06-03 07:00:00Z]
    last_run_at = ~U[2026-06-02 07:13:00Z]

    RuntimeStore.upsert_lifecycle(path, "tests/standing", %{
      kind: "standing",
      phase: "awaiting",
      run_id: "20260602T090000+0200",
      next_due_at: next_due_at,
      last_run_at: last_run_at,
      review: %{
        "state" => "awaiting",
        "run_id" => "20260602T090000+0200",
        "accepted_run_id" => nil
      }
    })

    assert [
             %{
               fiber_id: "tests/standing",
               metadata: %{
                 kind: "standing",
                 phase: "awaiting",
                 run_id: "20260602T090000+0200",
                 next_due_at: ^next_due_at,
                 last_run_at: ^last_run_at,
                 review: %{
                   "state" => "awaiting",
                   "run_id" => "20260602T090000+0200",
                   "accepted_run_id" => nil
                 }
               }
             }
           ] = RuntimeStore.list_lifecycle(path)

    RuntimeStore.delete_lifecycle(path, "tests/standing")
    assert [] = RuntimeStore.list_lifecycle(path)
  after
    System.tmp_dir!()
    |> Path.join("shuttle-runtime-store-test-*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)
  end

  defp temp_db_path do
    Path.join(
      System.tmp_dir!(),
      "shuttle-runtime-store-test-#{System.unique_integer([:positive])}/runtime.db"
    )
  end
end
