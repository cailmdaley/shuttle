defmodule ShuttleWeb.SessionControllerTest do
  use ExUnit.Case
  import Plug.Conn
  import Phoenix.ConnTest

  alias Shuttle.RuntimeStore

  @endpoint ShuttleWeb.Endpoint

  test "session-set writes runtime store and evicts legacy frontmatter session" do
    root =
      Path.join(System.tmp_dir!(), "shuttle-session-set-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    runtime_store = Path.join(root, "runtime.db")
    path = write_fiber!(store, "tests/session-set", legacy_session: "old-session")

    with_env(%{"LOOM_HOMES" => store, "SHUTTLE_RUNTIME_STORE" => runtime_store}, fn ->
      conn =
        post(
          api_conn(),
          "/api/v1/session",
          Jason.encode!(%{
            "action" => "set",
            "fiber" => "tests/session-set",
            "session_id" => "new-session",
            "agent" => "codex"
          })
        )

      assert conn.status == 200
      assert conn.resp_body == "session new-session stored for tests/session-set\n"

      frontmatter = path |> File.read!() |> frontmatter()
      refute frontmatter =~ "session:"

      assert [
               %{
                 fiber_id: "tests/session-set",
                 metadata: %{
                   kind: "oneshot",
                   phase: "dispatched",
                   session: %{
                     "id" => "new-session",
                     "agent" => "codex",
                     "dispatched_at" => _
                   }
                 }
               }
             ] = RuntimeStore.list_lifecycle(runtime_store)
    end)

    File.rm_rf(root)
  end

  test "session-set accepts an intrinsic UID and writes the slug address with UID metadata" do
    root =
      Path.join(System.tmp_dir!(), "shuttle-session-set-uid-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    runtime_store = Path.join(root, "runtime.db")
    uid = "01KTCWMQ8H8PHC2X38CFZ8AA1R"
    path = write_fiber!(store, "tests/session-set-uid", legacy_session: "old-session", id: uid)

    with_env(%{"LOOM_HOMES" => store, "SHUTTLE_RUNTIME_STORE" => runtime_store}, fn ->
      conn =
        post(
          api_conn(),
          "/api/v1/session",
          Jason.encode!(%{
            "action" => "set",
            "fiber" => uid,
            "session_id" => "new-session",
            "agent" => "codex"
          })
        )

      assert conn.status == 200
      assert conn.resp_body == "session new-session stored for tests/session-set-uid\n"

      frontmatter = path |> File.read!() |> frontmatter()
      refute frontmatter =~ "session:"

      assert [
               %{
                 fiber_id: "tests/session-set-uid",
                 runtime_key: ^uid,
                 metadata: %{
                   uid: ^uid,
                   kind: "oneshot",
                   phase: "dispatched",
                   session: %{"id" => "new-session", "agent" => "codex"}
                 }
               }
             ] = RuntimeStore.list_lifecycle(runtime_store)
    end)

    File.rm_rf(root)
  end

  test "session-clear removes runtime session and evicts legacy frontmatter session" do
    root =
      Path.join(System.tmp_dir!(), "shuttle-session-clear-#{System.unique_integer([:positive])}")

    store = Path.join(root, "loom")
    runtime_store = Path.join(root, "runtime.db")
    path = write_fiber!(store, "tests/session-clear", legacy_session: "old-session")

    with_env(%{"LOOM_HOMES" => store, "SHUTTLE_RUNTIME_STORE" => runtime_store}, fn ->
      RuntimeStore.upsert_lifecycle(runtime_store, "tests/session-clear", %{
        kind: "oneshot",
        phase: "dispatched",
        session: %{"id" => "old-session", "agent" => "codex"}
      })

      conn =
        post(
          api_conn(),
          "/api/v1/session",
          Jason.encode!(%{"action" => "clear", "fiber" => "tests/session-clear"})
        )

      assert conn.status == 200
      assert conn.resp_body == "session cleared for tests/session-clear\n"

      frontmatter = path |> File.read!() |> frontmatter()
      refute frontmatter =~ "session:"

      assert [
               %{
                 fiber_id: "tests/session-clear",
                 metadata: metadata
               }
             ] = RuntimeStore.list_lifecycle(runtime_store)

      refute Map.has_key?(metadata, :session)
    end)

    File.rm_rf(root)
  end

  defp write_fiber!(store, fiber_id, opts) do
    segments = String.split(fiber_id, "/")
    basename = List.last(segments)
    dir = Path.join([store, ".felt" | segments])
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{basename}.md")

    session_block =
      case Keyword.get(opts, :legacy_session) do
        nil ->
          ""

        session ->
          """
            session:
              id: #{session}
          """
      end

    File.write!(path, """
    ---
    #{id_field(opts)}
    name: Session test
    status: active
    shuttle:
      enabled: true
      kind: oneshot
    #{session_block}---

    Body.
    """)

    path
  end

  defp id_field(opts) do
    case Keyword.get(opts, :id) do
      nil -> ""
      id -> "id: #{id}\n"
    end
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
end
