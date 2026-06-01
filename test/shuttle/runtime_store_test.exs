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

  defp temp_db_path do
    Path.join(
      System.tmp_dir!(),
      "shuttle-runtime-store-test-#{System.unique_integer([:positive])}/runtime.db"
    )
  end
end
