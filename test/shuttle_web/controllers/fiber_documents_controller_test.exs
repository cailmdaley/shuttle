defmodule ShuttleWeb.FiberDocumentsControllerTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ShuttleWeb.Endpoint

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "shuttle-fiber-documents-controller-#{System.unique_integer([:positive])}"
      )

    store = Path.join(root, "loom")
    File.mkdir_p!(store)

    old_loom_homes = System.get_env("LOOM_HOMES")
    old_shuttle_host = System.get_env("SHUTTLE_HOST")

    System.put_env("LOOM_HOMES", store)
    System.put_env("SHUTTLE_HOST", "test-host")

    on_exit(fn ->
      restore_env("LOOM_HOMES", old_loom_homes)
      restore_env("SHUTTLE_HOST", old_shuttle_host)
      File.rm_rf(root)
    end)

    {:ok, store: store}
  end

  test "GET /api/v1/fibers returns daemon-local felt JSON with path metadata", %{store: store} do
    write_fiber!(store, "tests/document", """
    ---
    name: Document route
    status: active
    tags:
      - shuttle
    shuttle:
      enabled: true
      host: test-host
    ---

    Body.
    """)

    report = Path.join([store, ".felt", "tests", "document", "report.html"])
    File.write!(report, "<p>report</p>\n")

    conn = get(api_conn(), "/api/v1/fibers")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["host"] == "test-host"
    assert body["felt_stores"] == [store]

    assert [
             %{
               "felt_store" => ^store,
               "path" => "tests/document/document.md",
               "report_path" => ^report,
               "fiber" => %{
                 "id" => "tests/document",
                 "name" => "Document route",
                 "status" => "active",
                 "shuttle" => %{"enabled" => true, "host" => "test-host"}
               }
             }
           ] = body["fibers"]

    refute Map.has_key?(hd(body["fibers"])["fiber"], "body")
  end

  test "GET /api/v1/fibers?body=true includes felt bodies", %{store: store} do
    write_fiber!(store, "tests/body", """
    ---
    name: Body route
    status: open
    ---

    Body text.
    """)

    conn = get(api_conn(), "/api/v1/fibers?body=true")

    assert conn.status == 200
    assert [%{"fiber" => %{"body" => "Body text."}}] = Jason.decode!(conn.resp_body)["fibers"]
  end

  test "GET /api/v1/fibers?shuttle=true returns only fibers with a shuttle block", %{store: store} do
    write_fiber!(store, "tests/managed", """
    ---
    name: Managed
    status: active
    shuttle:
      enabled: true
      host: test-host
    ---

    Body.
    """)

    write_fiber!(store, "tests/plain", """
    ---
    name: Plain todo
    status: open
    due: 2026-01-01
    ---

    Body.
    """)

    # Unfiltered: both fibers come back (back-compatible default).
    all = get(api_conn(), "/api/v1/fibers")
    assert all.status == 200

    all_names =
      Jason.decode!(all.resp_body)["fibers"]
      |> Enum.map(& &1["fiber"]["name"])
      |> Enum.sort()

    assert all_names == ["Managed", "Plain todo"]

    # shuttle=true: only the fiber carrying a non-empty `shuttle:` block.
    only = get(api_conn(), "/api/v1/fibers?shuttle=true")
    assert only.status == 200
    assert [%{"fiber" => %{"name" => "Managed"}}] = Jason.decode!(only.resp_body)["fibers"]
  end

  test "GET /api/v1/fibers canonicalizes ids through symlinked stores", %{store: store} do
    # Build the shapepipe shape: loom's `.felt/shapepipe` is a symlink into a
    # separate project store. `felt ls` walks loom and reports the traversal id
    # `shapepipe/review-ngmix`, but the realpath lands in the project store where
    # the slug is `review-ngmix` — which is also how /state keys the runtime.
    # The endpoint must emit the canonical (project-relative) id so the kanban
    # join matches, while keeping `path` store-relative for file access.
    root = Path.dirname(store)
    project = Path.join(root, "shapepipe")

    write_fiber!(project, "review-ngmix", """
    ---
    name: Ngmix review
    status: active
    shuttle:
      enabled: true
      host: test-host
    ---

    Body.
    """)

    File.mkdir_p!(Path.join(store, ".felt"))
    File.ln_s!(Path.join(project, ".felt"), Path.join([store, ".felt", "shapepipe"]))

    conn = get(api_conn(), "/api/v1/fibers")
    assert conn.status == 200

    entry =
      Jason.decode!(conn.resp_body)["fibers"]
      |> Enum.find(&(&1["fiber"]["name"] == "Ngmix review"))

    assert entry["fiber"]["id"] == "review-ngmix"
    assert entry["path"] == "shapepipe/review-ngmix/review-ngmix.md"
    assert entry["felt_store"] == store
  end

  test "GET /api/v1/fibers survives stray non-fiber .md files in a store", %{store: store} do
    # A store with a SPEC.md (no frontmatter) makes `felt ls` print a stderr
    # warning while still emitting valid JSON on stdout. Folding stderr into
    # stdout used to corrupt the JSON and 500 the whole endpoint.
    write_fiber!(store, "tests/real", """
    ---
    name: Real fiber
    status: active
    ---

    Body.
    """)

    File.write!(Path.join([store, ".felt", "SPEC.md"]), "no frontmatter here\n")

    conn = get(api_conn(), "/api/v1/fibers")
    assert conn.status == 200
    fibers = Jason.decode!(conn.resp_body)["fibers"]
    assert Enum.any?(fibers, &(&1["fiber"]["name"] == "Real fiber"))
  end

  test "GET /api/v1/fibers/:id resolves a single fiber by canonical id (fast path)",
       %{store: store} do
    write_fiber!(store, "tests/single", """
    ---
    name: Single fiber
    status: active
    shuttle:
      enabled: true
      host: test-host
    ---

    Body text.
    """)

    report = Path.join([store, ".felt", "tests", "single", "report.html"])
    File.write!(report, "<p>report</p>\n")

    conn = get(api_conn(), "/api/v1/fibers/tests/single")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["host"] == "test-host"

    assert [
             %{
               "felt_store" => ^store,
               "path" => "tests/single/single.md",
               "report_path" => ^report,
               "fiber" => %{"id" => "tests/single", "name" => "Single fiber"}
             }
           ] = body["fibers"]

    # Default omits the body (metadata-only, like the locate path).
    refute Map.has_key?(hd(body["fibers"])["fiber"], "body")
  end

  test "GET /api/v1/fibers emits frontmatter ULID as the logical fiber id", %{store: store} do
    ulid = "01JZ0000000000000000000000"

    write_fiber!(store, "tests/ulid", """
    ---
    id: #{ulid}
    name: ULID fiber
    status: active
    shuttle:
      enabled: true
      host: test-host
    ---

    Body.
    """)

    conn = get(api_conn(), "/api/v1/fibers")
    assert conn.status == 200

    assert [
             %{
               "path" => "tests/ulid/ulid.md",
               "fiber" => %{
                 "id" => ^ulid,
                 "slug" => "tests/ulid",
                 "name" => "ULID fiber"
               }
             }
           ] = Jason.decode!(conn.resp_body)["fibers"]
  end

  test "GET /api/v1/fibers/:id resolves frontmatter ULIDs and migration-era slugs",
       %{store: store} do
    ulid = "01JZ0000000000000000000001"

    write_fiber!(store, "tests/ulid-show", """
    ---
    id: #{ulid}
    name: ULID show
    status: active
    shuttle:
      enabled: true
      host: test-host
    ---

    Body.
    """)

    by_ulid = get(api_conn(), "/api/v1/fibers/#{ulid}")
    assert by_ulid.status == 200

    assert [
             %{
               "path" => "tests/ulid-show/ulid-show.md",
               "fiber" => %{"id" => ^ulid, "slug" => "tests/ulid-show"}
             }
           ] = Jason.decode!(by_ulid.resp_body)["fibers"]

    by_slug = get(api_conn(), "/api/v1/fibers/tests/ulid-show")
    assert by_slug.status == 200

    assert [
             %{
               "path" => "tests/ulid-show/ulid-show.md",
               "fiber" => %{"id" => ^ulid, "slug" => "tests/ulid-show"}
             }
           ] = Jason.decode!(by_slug.resp_body)["fibers"]
  end

  test "GET /api/v1/fibers/:id?body=true includes the felt body", %{store: store} do
    write_fiber!(store, "tests/single-body", """
    ---
    name: Single with body
    status: open
    ---

    The body content.
    """)

    conn = get(api_conn(), "/api/v1/fibers/tests/single-body?body=true")

    assert conn.status == 200

    assert [%{"fiber" => %{"body" => "The body content."}}] =
             Jason.decode!(conn.resp_body)["fibers"]
  end

  test "GET /api/v1/fibers/:id resolves a symlink-traversed fiber via the canonical id (scan fallback)",
       %{store: store} do
    # Mirror the list endpoint's shapepipe case: loom's `.felt/shapepipe` is a
    # symlink into a separate project store. felt's traversal id is
    # `shapepipe/review-ngmix`, but the canonical (project-relative) id is
    # `review-ngmix` — so `felt show review-ngmix` in the loom store misses and
    # the endpoint must fall back to scanning to match the canonical id.
    root = Path.dirname(store)
    project = Path.join(root, "shapepipe")

    write_fiber!(project, "review-ngmix", """
    ---
    name: Ngmix review
    status: active
    shuttle:
      enabled: true
      host: test-host
    ---

    Body.
    """)

    File.mkdir_p!(Path.join(store, ".felt"))
    File.ln_s!(Path.join(project, ".felt"), Path.join([store, ".felt", "shapepipe"]))

    conn = get(api_conn(), "/api/v1/fibers/review-ngmix")
    assert conn.status == 200

    assert [
             %{
               "felt_store" => ^store,
               "path" => "shapepipe/review-ngmix/review-ngmix.md",
               "fiber" => %{"id" => "review-ngmix", "name" => "Ngmix review"}
             }
           ] = Jason.decode!(conn.resp_body)["fibers"]
  end

  test "GET /api/v1/fibers/:id returns an empty fiber list for an unknown id", %{store: store} do
    write_fiber!(store, "tests/present", """
    ---
    name: Present
    status: active
    ---

    Body.
    """)

    conn = get(api_conn(), "/api/v1/fibers/tests/absent")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["fibers"] == []
  end

  defp write_fiber!(store, fiber_id, content) do
    segments = String.split(fiber_id, "/")
    basename = List.last(segments)
    dir = Path.join([store, ".felt" | segments])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{basename}.md"), content)
  end

  defp api_conn do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
