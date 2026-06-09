defmodule ShuttleWeb.FiberDocumentsControllerTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ShuttleWeb.Endpoint

  alias Shuttle.{Remote, RemoteFiberRegistry}

  # Deterministic HTTP stub for the cross-host composite test: scripts the
  # remote daemon's `/api/v1/fibers?shuttle=true` response so the local
  # RemoteFiberRegistry caches a known feed without a real tunnel.
  defmodule StubFiberClient do
    @behaviour Shuttle.RemoteRegistry.Client
    use Agent

    def start_link(_ \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def set(url, response), do: Agent.update(__MODULE__, &Map.put(&1, url, response))

    @impl true
    def get(url, _timeout_ms), do: Agent.get(__MODULE__, &Map.get(&1, url, {:error, :not_set}))
  end

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

    File.write!(Path.join([store, ".felt", "tests", "document", "report.html"]), "<p>report</p>\n")

    # report_path is `dirname(felt.path)/report.html` — felt's carried path is
    # symlink-canonicalized (on macOS the tmp store's /var → /private/var), and
    # Portolan serves it as an absolute path, so assert against that realpath.
    report = real_report_path(store, "tests/document")

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

  test "GET /api/v1/fibers?shuttle=true serves only this daemon's owned shuttle rows",
       %{store: store} do
    # Owned: shuttle block pinned to this daemon's host.
    write_fiber!(store, "tests/managed", """
    ---
    name: Managed
    status: active
    shuttle:
      kind: oneshot
      host: test-host
    ---

    Body.
    """)

    # Owned by ANOTHER host: physically rooted here (so it lands in the local
    # walk / document cache) but pinned to a peer. Slice 7: the owner-only feed
    # never serves a peer's fiber — it belongs to that host's feed, and a viewer
    # concatenates owners' answers rather than merging a mirror copy.
    write_fiber!(store, "tests/elsewhere", """
    ---
    name: Owned elsewhere
    status: active
    shuttle:
      kind: oneshot
      host: other-host
    ---

    Body.
    """)

    # Unowned: a shuttle block with no host:. Detected (it has a block) but not
    # considered — it names no daemon, so no daemon's feed claims it.
    write_fiber!(store, "tests/unowned", """
    ---
    name: Unowned draft
    status: open
    shuttle:
      kind: oneshot
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

    # Unfiltered: every fiber comes back (the content/search reader path).
    all = get(api_conn(), "/api/v1/fibers")
    assert all.status == 200

    all_names =
      Jason.decode!(all.resp_body)["fibers"]
      |> Enum.map(& &1["fiber"]["name"])
      |> Enum.sort()

    assert all_names == ["Managed", "Owned elsewhere", "Plain todo", "Unowned draft"]

    # shuttle=true: ONLY the row this daemon owns (shuttle block + host == own).
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

  test "GET /api/v1/fibers serves the flat symlinked-substore root (lightcone shape)",
       %{store: store} do
    # The case the old `entry_point`-guessing path-deriver got WRONG. loom's
    # `.felt/lightcone` symlinks into a project store whose ROOT fiber is FLAT —
    # `lightcone.md` directly in `.felt/`, not `lightcone/lightcone.md`. felt's
    # traversal id is `lightcone/lightcone` (served-store prefix), but the file
    # is flat. The old deriver produced `lightcone/lightcone/lightcone.md` (a
    # path that does not exist) and a `report.html` one directory too deep. The
    # leaf shape is now READ from felt's carried path, so both come out right.
    root = Path.dirname(store)
    project = Path.join(root, "lightcone")

    # Flat root fiber: the .md lives directly under the project's .felt/.
    File.mkdir_p!(Path.join(project, ".felt"))

    File.write!(Path.join([project, ".felt", "lightcone.md"]), """
    ---
    name: Lightcone root
    status: active
    shuttle:
      enabled: true
      host: test-host
    ---

    Body.
    """)

    File.write!(Path.join([project, ".felt", "report.html"]), "<p>flat report</p>\n")

    File.mkdir_p!(Path.join(store, ".felt"))
    File.ln_s!(Path.join(project, ".felt"), Path.join([store, ".felt", "lightcone"]))

    conn = get(api_conn(), "/api/v1/fibers")
    assert conn.status == 200

    entry =
      Jason.decode!(conn.resp_body)["fibers"]
      |> Enum.find(&(&1["fiber"]["name"] == "Lightcone root"))

    # Wire path stays served-store-relative and FLAT — the served file at
    # `<store>/.felt/lightcone/lightcone.md` (via the symlink) actually exists.
    assert entry["path"] == "lightcone/lightcone.md"
    assert File.exists?(Path.join([store, ".felt", entry["path"]]))

    # report.html is the sibling of the flat .md in the real project store, NOT
    # one directory deeper. Asserted via the realpath felt carries.
    {realdir, 0} = System.cmd("realpath", [Path.join(project, ".felt")])
    expected_report = Path.join(String.trim(realdir), "report.html")
    assert entry["report_path"] == expected_report
    assert File.exists?(entry["report_path"])
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

    File.write!(Path.join([store, ".felt", "tests", "single", "report.html"]), "<p>report</p>\n")
    report = real_report_path(store, "tests/single")

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

  test "GET /api/v1/fibers/composite stamps origin and reports the local origin (no remotes)",
       %{store: store} do
    write_fiber!(store, "tests/managed", """
    ---
    name: Managed
    status: active
    shuttle:
      kind: oneshot
      host: test-host
    ---

    Body.
    """)

    conn = get(api_conn(), "/api/v1/fibers/composite")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body["host"] == "test-host"

    # Only this daemon's owned shuttle row, stamped with its origin.
    assert [%{"fiber" => %{"name" => "Managed"}, "origin" => "test-host"}] = body["fibers"]

    # The local origin is reported (kind: local); no remotes configured.
    assert body["origins"]["test-host"]["kind"] == "local"
    assert body["origins"]["test-host"]["stale"] == false
    assert body["origins"]["test-host"]["fiber_count"] == 1
    assert Map.keys(body["origins"]) == ["test-host"]
  end

  test "GET /api/v1/fibers/composite concatenates the local feed with a cached remote feed",
       %{store: store} do
    write_fiber!(store, "tests/managed", """
    ---
    name: Managed
    status: active
    shuttle:
      kind: oneshot
      host: test-host
    ---

    Body.
    """)

    remote = %Remote{name: "candide", url: "http://localhost:4001"}

    remote_body =
      Jason.encode!(%{
        "host" => "candide",
        "fibers" => [
          %{
            "felt_store" => "/loom",
            "path" => "tests/remote/remote.md",
            "fiber" => %{"id" => "tests/remote", "name" => "Remote work", "status" => "active"},
            "runtime" => %{"tmux_session" => "shuttle-remote"}
          }
        ]
      })

    start_supervised!(StubFiberClient)
    StubFiberClient.set(Remote.fibers_url(remote), {:ok, remote_body})

    # Start the registry under its DEFAULT name so the controller's feeds/0
    # call (which targets Shuttle.RemoteFiberRegistry) sees it.
    start_supervised!(
      {RemoteFiberRegistry, remotes: [remote], client: StubFiberClient, auto_poll: false}
    )

    :ok = RemoteFiberRegistry.refresh_now()

    conn = get(api_conn(), "/api/v1/fibers/composite")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    by_origin = Map.new(body["fibers"], &{&1["origin"], &1})

    assert by_origin["test-host"]["fiber"]["name"] == "Managed"
    assert by_origin["candide"]["fiber"]["name"] == "Remote work"
    # Remote liveness rides the owner-stamped runtime on the feed row.
    assert by_origin["candide"]["runtime"]["tmux_session"] == "shuttle-remote"

    assert body["origins"]["test-host"]["kind"] == "local"
    assert body["origins"]["candide"]["kind"] == "remote"
    assert body["origins"]["candide"]["stale"] == false
    assert body["origins"]["candide"]["fiber_count"] == 1
  end

  test "GET /api/v1/fibers/composite includes local human due-date cards the owner feed omits",
       %{store: store} do
    # Owner shuttle work — in both the owner feed and the composite.
    write_fiber!(store, "tests/managed", """
    ---
    name: Managed
    status: active
    shuttle:
      kind: oneshot
      host: test-host
    ---

    Body.
    """)

    # A human-tracked todo: open + due, NO shuttle block. The owner feed
    # (`?shuttle=true`) drops it; the composite board must re-include it.
    write_fiber!(store, "tests/human-todo", """
    ---
    name: Human todo
    status: open
    due: 2026-12-01
    ---

    Body.
    """)

    # A shuttle fiber that ALSO carries a due: must appear exactly once (owner
    # feed), never double-counted into the human-due path.
    write_fiber!(store, "tests/owner-due", """
    ---
    name: Owner with due
    status: active
    due: 2026-11-01
    shuttle:
      kind: oneshot
      host: test-host
    ---

    Body.
    """)

    # A closed due card is off the board — status gates before due.
    write_fiber!(store, "tests/done-todo", """
    ---
    name: Done todo
    status: closed
    due: 2026-01-01
    ---

    Body.
    """)

    conn = get(api_conn(), "/api/v1/fibers/composite")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    names = body["fibers"] |> Enum.map(& &1["fiber"]["name"]) |> Enum.sort()
    assert names == ["Human todo", "Managed", "Owner with due"]

    # Every local row — owner and human-due alike — is stamped the local origin.
    assert Enum.all?(body["fibers"], &(&1["origin"] == "test-host"))

    # The shuttle+due fiber is present exactly once (no double-count).
    assert Enum.count(body["fibers"], &(&1["fiber"]["name"] == "Owner with due")) == 1

    # fiber_count reflects owner + human-due together.
    assert body["origins"]["test-host"]["fiber_count"] == 3

    # The owner feed itself stays strictly owner-only — the human todo never
    # leaks into `?shuttle=true`.
    only = get(api_conn(), "/api/v1/fibers?shuttle=true")
    owner_names = Jason.decode!(only.resp_body)["fibers"] |> Enum.map(& &1["fiber"]["name"]) |> Enum.sort()
    assert owner_names == ["Managed", "Owner with due"]
  end

  defp write_fiber!(store, fiber_id, content) do
    segments = String.split(fiber_id, "/")
    basename = List.last(segments)
    dir = Path.join([store, ".felt" | segments])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{basename}.md"), content)
  end

  # The report_path the endpoint emits: `dirname(felt.path)/report.html`, where
  # felt's `path` is symlink-canonicalized. Mirror that by realpath'ing the
  # report file's directory so the assertion is robust to macOS's /var symlink.
  defp real_report_path(store, fiber_id) do
    segments = String.split(fiber_id, "/")
    dir = Path.join([store, ".felt" | segments])
    {realdir, 0} = System.cmd("realpath", [dir])
    Path.join(String.trim(realdir), "report.html")
  end

  defp api_conn do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
