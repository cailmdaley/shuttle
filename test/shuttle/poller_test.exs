defmodule Shuttle.PollerTest do
  use ExUnit.Case

  alias Shuttle.Poller
  alias Shuttle.Dispatcher

  # ── Mock Runner ──

  defmodule MockRunner do
    @behaviour Shuttle.Runner

    use Agent

    def start_link(_ \\ []) do
      Agent.start_link(
        fn ->
          %{
            commands: [],
            tmux_sessions: MapSet.new(),
            fibers: %{},
            shuttle: %{},
            felt_ls: [],
            felt_ls_delay_ms: 0,
            new_session_delay_ms: 0
          }
        end,
        name: __MODULE__
      )
    end

    def reset do
      # Remove any fiber files written by set_shuttle so tests start clean.
      File.rm_rf("/tmp/.felt")

      Agent.update(__MODULE__, fn _ ->
        %{
          commands: [],
          tmux_sessions: MapSet.new(),
          fibers: %{},
          shuttle: %{},
          felt_ls: [],
          felt_ls_delay_ms: 0,
          new_session_delay_ms: 0
        }
      end)
    end

    # Carry a felt-style absolute `path` so the poller's store-ownership check
    # (which reads felt's `path`) sees the fiber as rooted in `/tmp`. Preserves
    # an existing path when `set_shuttle` already wrote one, and synthesizes the
    # canonical `<id>/<leaf>.md` shape otherwise, mirroring real felt's output.
    def set_fiber(id, fiber) do
      Agent.update(__MODULE__, fn state ->
        existing_path = get_in(state.fibers, [id, "path"])
        path = Map.get(fiber, "path") || existing_path || synth_path(id)
        put_in(state.fibers[id], Map.put(fiber, "path", path))
      end)
    end

    defp synth_path(id) do
      leaf = id |> String.split("/") |> List.last()
      realpath(Path.join(["/tmp/.felt", id, "#{leaf}.md"]))
    end

    # Write a real .md file carrying the given shuttle: block and felt status so
    # the poller can discover host ownership from the filesystem while reading
    # shuttle metadata through the mocked `felt ls` / `felt show` JSON surfaces.
    # The status defaults to "active" — pass an explicit value for tests that
    # verify eligibility gates (closed, untracked, etc.).
    def set_shuttle(id, yaml, status \\ "active") do
      # Post-cutover, every installed block carries an explicit `host:` equal
      # to the owning daemon's own_host_id (the strict eligibility predicate
      # has no nil-wildcard). The factory mirrors that: a block whose YAML
      # omits `host:` is stamped with the test daemon's identity
      # ("test-host", set via SHUTTLE_HOST in config/test.exs) so generic
      # dispatch tests stay eligible. Host-specific tests pass an explicit
      # `host:` line, which wins.
      yaml =
        if Regex.match?(~r/^\s*host\s*:/m, yaml) do
          yaml
        else
          String.trim_trailing(yaml) <> "\nhost: test-host\n"
        end

      felt_dir = "/tmp/.felt"
      segments = String.split(id, "/")
      basename = List.last(segments)
      dir_path = Path.join([felt_dir | segments] ++ ["#{basename}.md"])
      File.mkdir_p!(Path.dirname(dir_path))
      indented = yaml |> String.trim() |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
      File.write!(dir_path, "---\nstatus: #{status}\nshuttle:\n#{indented}\n---\nbody\n")

      # Mirror real felt: carry the absolute, symlink-resolved on-disk `path`.
      # The poller reads this `path` to decide store ownership instead of
      # walking the filesystem, so the mock's `felt ls`/`felt show` JSON must
      # expose it the same way the real CLI now does.
      carried_path = realpath(dir_path)

      shuttle_block =
        case YamlElixir.read_from_string(yaml) do
          {:ok, data} when is_map(data) -> data
          _ -> %{}
        end

      Agent.update(__MODULE__, fn state ->
        fiber =
          state.fibers
          |> Map.get(id, %{
            "id" => id,
            "name" => id,
            "created_at" => "2026-04-28T00:00:00Z",
            "tags" => ["constitution"]
          })
          |> Map.put("status", status)
          |> Map.put("shuttle", shuttle_block)
          |> Map.put("path", carried_path)

        state
        |> put_in([:shuttle, id], yaml)
        |> put_in([:fibers, id], fiber)
      end)
    end

    # Absolute, symlink-resolved path of a written fiber file. macOS resolves
    # `/tmp` and `/var` to `/private/...`; mirror that so the carried path
    # matches the store realpath the poller computes for ownership.
    defp realpath(path), do: resolve_tmp_symlink(Path.expand(path))

    defp resolve_tmp_symlink("/tmp/" <> rest), do: "/private/tmp/" <> rest
    defp resolve_tmp_symlink("/var/" <> rest), do: "/private/var/" <> rest
    defp resolve_tmp_symlink(path), do: path

    # Kept for backward compat; no longer consulted by discover_candidates
    # (discovery now walks files for shuttle: blocks).  Still used by the
    # mock's felt ls handler which other code paths may call.
    def set_felt_ls(fibers), do: Agent.update(__MODULE__, &%{&1 | felt_ls: fibers})

    def set_felt_ls_delay(ms),
      do: Agent.update(__MODULE__, &Map.put(&1, :felt_ls_delay_ms, ms))

    def add_tmux_session(session),
      do: Agent.update(__MODULE__, &%{&1 | tmux_sessions: MapSet.put(&1.tmux_sessions, session)})

    def remove_tmux_session(session),
      do:
        Agent.update(__MODULE__, &%{&1 | tmux_sessions: MapSet.delete(&1.tmux_sessions, session)})

    def set_new_session_delay(ms),
      do: Agent.update(__MODULE__, &Map.put(&1, :new_session_delay_ms, ms))

    def commands, do: Agent.get(__MODULE__, & &1.commands)

    @impl true
    def cmd(command, args, _opts) do
      Agent.update(__MODULE__, fn state ->
        %{state | commands: state.commands ++ [{command, args}]}
      end)

      full_args = Enum.join(args, " ")

      cond do
        command == "felt" and String.contains?(full_args, "ls") ->
          delay_ms = Agent.get(__MODULE__, &Map.get(&1, :felt_ls_delay_ms, 0))
          if delay_ms > 0, do: Process.sleep(delay_ms)

          show_all =
            case Enum.find_index(args, &(&1 in ["-s", "--status"])) do
              nil -> false
              idx -> Enum.at(args, idx + 1) == "all"
            end

          fibers =
            Agent.get(__MODULE__, fn state ->
              entries = if state.felt_ls == [], do: Map.values(state.fibers), else: state.felt_ls

              if show_all do
                entries
              else
                Enum.filter(entries, fn fiber ->
                  Map.get(fiber, "status") in ["open", "active"]
                end)
              end
            end)

          {Jason.encode!(fibers), 0}

        command == "felt" and String.contains?(full_args, "show") and
            String.contains?(full_args, "--field shuttle") ->
          fiber_id = extract_fiber_id(args)
          shuttle = Agent.get(__MODULE__, & &1.shuttle)
          {Map.get(shuttle, fiber_id, ""), 0}

        command == "felt" and String.contains?(full_args, "show") ->
          # `felt show --json` rounds-trip-the-bytes (felt v1.0.4+): tool-owned
          # frontmatter namespaces like `shuttle:` and `tags:` appear as flat
          # top-level JSON keys, alongside the parsed fields. The mock keeps
          # the fiber map intact to mirror this.
          fiber_id = extract_fiber_id(args)
          fibers = Agent.get(__MODULE__, & &1.fibers)

          case Map.get(fibers, fiber_id) do
            nil -> {"fiber not found", 1}
            fiber -> {Jason.encode!(fiber), 0}
          end

        command == "tmux" and hd(args) == "has-session" ->
          session = Enum.at(args, 2)
          sessions = Agent.get(__MODULE__, & &1.tmux_sessions)

          if tmux_session_exists?(sessions, session) do
            {"", 0}
          else
            {"can't find session", 1}
          end

        command == "tmux" and hd(args) == "new-session" ->
          session = Enum.at(args, 3)
          add_tmux_session(session)
          delay_ms = Agent.get(__MODULE__, &Map.get(&1, :new_session_delay_ms, 0))
          if delay_ms > 0, do: Process.sleep(delay_ms)
          {"", 0}

        command == "tmux" and hd(args) == "kill-session" ->
          session = Enum.at(args, 2)
          remove_tmux_session(session)
          {"", 0}

        command == "tmux" and hd(args) == "rename-session" ->
          ["rename-session", "-t", "=" <> old_name, new_name] = args

          Agent.update(__MODULE__, fn state ->
            if MapSet.member?(state.tmux_sessions, old_name) do
              sessions = state.tmux_sessions |> MapSet.delete(old_name) |> MapSet.put(new_name)
              %{state | tmux_sessions: sessions}
            else
              state
            end
          end)

          {"", 0}

        command == "tmux" and hd(args) == "ls" ->
          sessions = Agent.get(__MODULE__, & &1.tmux_sessions)
          output = sessions |> MapSet.to_list() |> Enum.join("\n")
          {output, 0}

        true ->
          {"", 0}
      end
    end

    defp extract_fiber_id(args) do
      # args like ["show", "tests/haiku", "--json"] or
      # ["show", "tests/haiku", "--field", "shuttle"]
      args
      |> Enum.reject(&(&1 in ["show", "--json", "--field", "shuttle"]))
      |> List.first("")
    end

    defp tmux_session_exists?(sessions, "=" <> session), do: MapSet.member?(sessions, session)

    defp tmux_session_exists?(sessions, session) do
      Enum.any?(sessions, &(&1 == session or String.starts_with?(&1, session <> "/")))
    end
  end

  # ── Setup ──

  setup do
    start_supervised!(MockRunner)
    MockRunner.reset()
    :ok
  end

  # ── Helpers ──

  # Minimal shuttle: block YAML for a oneshot fiber ready for dispatch.
  @oneshot_shuttle "enabled: true\nkind: oneshot\n"

  defp make_fiber(id, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => id,
        "status" => "active",
        "tags" => ["constitution"],
        "created_at" => "2026-04-28T00:00:00Z"
      },
      attrs
    )
  end

  defp wait_until(fun, attempts \\ 20)
  defp wait_until(fun, 0), do: fun.()

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp felt_show_count do
    Enum.count(MockRunner.commands(), fn {cmd, args} ->
      cmd == "felt" and Enum.take(args, 1) == ["show"]
    end)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp new_session_scripts do
    MockRunner.commands()
    |> Enum.filter(fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)
    |> Enum.map(fn {_cmd, args} -> List.last(args) end)
  end

  defp append_review_comment(id, opts) do
    resume_mode = Keyword.fetch!(opts, :resume_mode)

    {out, code} =
      System.cmd(
        "felt",
        [
          "-C",
          "/tmp",
          "history",
          "append",
          id,
          "--kind",
          "review-comment",
          "-m",
          "",
          "--field",
          "resume_mode=#{resume_mode}"
        ],
        stderr_to_stdout: true
      )

    if code != 0, do: raise("felt history append failed (#{code}): #{out}")
  end

  # Mirror the dispatcher's at-spawn session record: a felt-history event whose
  # summary carries `session=<uuid>` (slice 6: felt history is the durable
  # session-id home, parsed back by extract_session_id at resume).
  defp append_dispatch_session(id, session_id) do
    {out, code} =
      System.cmd(
        "felt",
        [
          "-C",
          "/tmp",
          "history",
          "append",
          id,
          "--summary",
          "worker dispatched (agent=claude-sonnet) session=#{session_id}"
        ],
        stderr_to_stdout: true
      )

    if code != 0, do: raise("felt history append failed (#{code}): #{out}")
  end

  # ── Tests ──

  test "poller discovers and dispatches eligible fibers" do
    # Use a fiber ID unique to this test to avoid collisions with sessions left
    # alive by other tests' long-lived Pollers/Watchers.
    fiber = make_fiber("tests/haiku-dispatch")
    MockRunner.set_fiber("tests/haiku-dispatch", fiber)
    MockRunner.set_shuttle("tests/haiku-dispatch", @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_1,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Trigger a poll cycle manually
    send(poller, {:tick, Poller.snapshot(poller) |> Map.get(:tick_token)})

    assert wait_until(fn ->
             Enum.any?(MockRunner.commands(), fn {cmd, args} ->
               cmd == "tmux" and hd(args) == "new-session"
             end)
           end)

    # Check snapshot shows running worker
    assert wait_until(fn ->
             length(Poller.snapshot(poller).eligible) == 1
           end)

    snap = Poller.snapshot(poller)
    assert length(snap.eligible) == 1
    assert hd(snap.eligible).fiber_id == "tests/haiku-dispatch"
  end

  test "poller skips fibers targeted at a different shuttle host" do
    fiber = make_fiber("tests/host-mismatch")
    MockRunner.set_fiber("tests/host-mismatch", fiber)
    MockRunner.set_shuttle("tests/host-mismatch", "enabled: true\nkind: oneshot\nhost: candide\n")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_host_mismatch,
        runner: MockRunner,
        own_host_id: "local",
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)

    snap = Poller.snapshot(poller)
    assert snap.eligible == []
    assert snap.claimed_count == 0
  end

  test "poller dispatches fibers targeted at its own shuttle host" do
    fiber = make_fiber("tests/host-match")
    MockRunner.set_fiber("tests/host-match", fiber)
    MockRunner.set_shuttle("tests/host-match", "enabled: true\nkind: oneshot\nhost: candide\n")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_host_match,
        runner: MockRunner,
        own_host_id: "candide",
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             Enum.any?(MockRunner.commands(), fn {cmd, args} ->
               cmd == "tmux" and hd(args) == "new-session"
             end)
           end)

    assert wait_until(fn ->
             snap = Poller.snapshot(poller)
             length(snap.eligible) == 1 and hd(snap.eligible).fiber_id == "tests/host-match"
           end)
  end

  # The Poller defaults `own_host_id` from a three-step precedence chain:
  # SHUTTLE_HOST env var → ~/.shuttle/host file → :inet.gethostname().
  # Explicit `own_host_id:` opts always win; these tests cover the
  # resolution chain that drives production daemons. There is intentionally
  # no Application-config step and no "local" fallback — see
  # Shuttle.Poller.own_host_id/0.
  test "poller resolves own_host_id from SHUTTLE_HOST env var when set" do
    prev = System.get_env("SHUTTLE_HOST")
    System.put_env("SHUTTLE_HOST", "candide")

    try do
      {:ok, poller} =
        Poller.start_link(
          name: :test_poller_env_host,
          runner: MockRunner,
          poll_interval_ms: 60_000,
          felt_stores: ["/tmp"]
        )

      assert Poller.snapshot(poller).host == "candide"
    after
      # Restore the env var the test suite started with so sibling tests
      # (and the SHUTTLE_HOST pin set by config/test.exs) keep working.
      if prev, do: System.put_env("SHUTTLE_HOST", prev), else: System.delete_env("SHUTTLE_HOST")
    end
  end

  test "poller resolves own_host_id from ~/.shuttle/host file when SHUTTLE_HOST unset" do
    prev = System.get_env("SHUTTLE_HOST")
    prev_file = System.get_env("SHUTTLE_HOST_FILE")
    System.delete_env("SHUTTLE_HOST")
    path = Path.join(System.tmp_dir!(), "shuttle-host-#{System.unique_integer([:positive])}")
    File.write!(path, "candide\n")
    System.put_env("SHUTTLE_HOST_FILE", path)

    try do
      {:ok, poller} =
        Poller.start_link(
          name: :test_poller_host_file,
          runner: MockRunner,
          poll_interval_ms: 60_000,
          felt_stores: ["/tmp"]
        )

      assert Poller.snapshot(poller).host == "candide"
    after
      File.rm(path)

      if prev_file,
        do: System.put_env("SHUTTLE_HOST_FILE", prev_file),
        else: System.delete_env("SHUTTLE_HOST_FILE")

      if prev, do: System.put_env("SHUTTLE_HOST", prev), else: System.delete_env("SHUTTLE_HOST")
    end
  end

  test "poller falls back to :inet.gethostname when SHUTTLE_HOST and host file are unset" do
    prev = System.get_env("SHUTTLE_HOST")
    prev_file = System.get_env("SHUTTLE_HOST_FILE")
    System.delete_env("SHUTTLE_HOST")
    # Point the host-file source at a path that does not exist so the chain
    # genuinely falls through to the OS hostname regardless of the dev
    # machine's real ~/.shuttle/host.
    System.put_env(
      "SHUTTLE_HOST_FILE",
      Path.join(System.tmp_dir!(), "shuttle-host-absent-#{System.unique_integer([:positive])}")
    )

    {:ok, hostname} = :inet.gethostname()
    expected = to_string(hostname)

    try do
      {:ok, poller} =
        Poller.start_link(
          name: :test_poller_gethostname,
          runner: MockRunner,
          poll_interval_ms: 60_000,
          felt_stores: ["/tmp"]
        )

      assert Poller.snapshot(poller).host == expected
    after
      if prev_file,
        do: System.put_env("SHUTTLE_HOST_FILE", prev_file),
        else: System.delete_env("SHUTTLE_HOST_FILE")

      if prev, do: System.put_env("SHUTTLE_HOST", prev)
    end
  end

  test "poller uses the shuttle felt listing for discovery" do
    fiber = make_fiber("tests/projected-discovery")
    MockRunner.set_fiber("tests/projected-discovery", fiber)
    MockRunner.set_shuttle("tests/projected-discovery", @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_projected_listing,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)

    # The poller uses felt's cheap path-carrying projection; broad listing is
    # only a fallback for older remote felt binaries.
    assert wait_until(fn ->
             Enum.any?(MockRunner.commands(), fn {cmd, args} ->
               cmd == "felt" and
                 args == [
                   "ls",
                   "--json",
                   "--has-field",
                   "shuttle",
                   "--json-field",
                   "id,uid,status,shuttle,path,modified_at"
                 ]
             end)
           end)
  end

  test "poller caches document entries by uid and modified_at" do
    uid = "01JZ00000000000000000000CA"

    fiber =
      make_fiber("tests/cached-document", %{
        "uid" => uid,
        "modified_at" => "2026-06-06T01:00:00Z",
        "outcome" => "first"
      })

    MockRunner.set_fiber("tests/cached-document", fiber)
    MockRunner.set_shuttle("tests/cached-document", @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_document_cache,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        max_concurrent_workers: 0,
        felt_stores: ["/tmp"]
      )

    assert wait_until(fn ->
             get_in(Poller.snapshot(poller), [:document_cache, "entries"]) == 1
           end)

    first_stats = Poller.snapshot(poller)[:document_cache]
    first_show_count = felt_show_count()

    assert %{"hits" => 0, "misses" => 1, "entries" => 1} = first_stats
    assert first_show_count == 1

    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             stats = Poller.snapshot(poller)[:document_cache]
             stats["hits"] == 1 and stats["misses"] == 0
           end)

    assert felt_show_count() == first_show_count

    assert {:ok, body} = Poller.cached_fiber_documents(poller)
    assert [%{fiber: %{"id" => ^uid, "slug" => "tests/cached-document"}}] = body.fibers

    changed_fiber =
      make_fiber("tests/cached-document", %{
        "uid" => uid,
        "modified_at" => "2026-06-06T01:05:00Z",
        "name" => "changed document",
        "shuttle" => %{"enabled" => true, "kind" => "oneshot", "host" => "test-host"}
      })

    MockRunner.set_fiber("tests/cached-document", changed_fiber)
    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             stats = Poller.snapshot(poller)[:document_cache]
             stats["hits"] == 0 and stats["misses"] == 1
           end)

    assert felt_show_count() == first_show_count + 1
    assert {:ok, body} = Poller.cached_fiber_documents(poller)
    assert [%{fiber: %{"id" => ^uid, "name" => "changed document"}}] = body.fibers
  end

  test "owner feed stamps serve-time runtime onto an owned fiber with a live worker" do
    uid = "01JZ00000000000000000000RT"

    fiber =
      make_fiber("tests/aloft", %{
        "uid" => uid,
        "modified_at" => "2026-06-08T01:00:00Z"
      })

    MockRunner.set_fiber("tests/aloft", fiber)
    MockRunner.set_shuttle("tests/aloft", "enabled: true\nkind: oneshot\nhost: candide\n")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_runtime_stamp,
        runner: MockRunner,
        own_host_id: "candide",
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)

    # The fiber dispatches (lands in state.running) AND its document caches.
    assert wait_until(fn ->
             snap = Poller.snapshot(poller)

             length(snap.eligible) == 1 and
               get_in(snap, [:document_cache, "entries"]) >= 1
           end)

    assert {:ok, body} = Poller.cached_fiber_documents(poller)
    assert [%{runtime: runtime} = entry] = body.fibers
    # Liveness joins by uid (rename-safe): the served row's fiber uid matches
    # the runtime_key under which state.running tracks the live worker.
    assert get_in(entry, [:fiber, "uid"]) == uid
    assert %{tmux_session: session, state: _state, started_at: started} = runtime
    assert is_binary(session)
    assert is_integer(started)
    # No activity source by default → no phase, but last_activity_at still
    # present (falls back to meta/started_at) so the field is never missing.
    refute Map.has_key?(runtime, :phase)
    assert is_integer(runtime.last_activity_at)
  end

  test "owner feed stamps the REAL last_activity_at, distinct from started_at" do
    uid = "01JZ00000000000000000000RA"

    fiber =
      make_fiber("tests/realactivity", %{
        "uid" => uid,
        "modified_at" => "2026-06-08T01:00:00Z"
      })

    MockRunner.set_fiber("tests/realactivity", fiber)
    MockRunner.set_shuttle("tests/realactivity", "enabled: true\nkind: oneshot\nhost: candide\n")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_runtime_real_activity,
        runner: MockRunner,
        own_host_id: "candide",
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             snap = Poller.snapshot(poller)
             length(snap.eligible) == 1 and get_in(snap, [:document_cache, "entries"]) >= 1
           end)

    # Discover the running worker's session and its started_at, then inject an
    # activity record whose last_event_at is deliberately 90s BEFORE started_at.
    assert {:ok, %{fibers: [%{runtime: %{tmux_session: session, started_at: started}}]}} =
             Poller.cached_fiber_documents(poller)

    last_event_at = started - 90_000

    Application.put_env(:shuttle, :waiting_phases_source, fn ->
      %{session => %{last_event_at: last_event_at, phase: "waiting"}}
    end)

    on_exit(fn -> Application.delete_env(:shuttle, :waiting_phases_source) end)

    assert {:ok, %{fibers: [%{runtime: runtime}]}} = Poller.cached_fiber_documents(poller)
    # The served last_activity_at is the tracker's real timestamp — NOT started_at.
    assert runtime.last_activity_at == last_event_at
    assert runtime.last_activity_at != runtime.started_at
    assert runtime.phase == "waiting"
  end

  test "owner feed stamps phase: waiting when the live worker's session is waiting for input" do
    uid = "01JZ00000000000000000000RW"

    fiber =
      make_fiber("tests/waiting", %{
        "uid" => uid,
        "modified_at" => "2026-06-08T01:00:00Z"
      })

    MockRunner.set_fiber("tests/waiting", fiber)
    MockRunner.set_shuttle("tests/waiting", "enabled: true\nkind: oneshot\nhost: candide\n")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_runtime_waiting,
        runner: MockRunner,
        own_host_id: "candide",
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             snap = Poller.snapshot(poller)

             length(snap.eligible) == 1 and
               get_in(snap, [:document_cache, "entries"]) >= 1
           end)

    # Discover the running worker's session, then inject it as waiting.
    assert {:ok, %{fibers: [%{runtime: %{tmux_session: session}}]}} =
             Poller.cached_fiber_documents(poller)

    Application.put_env(:shuttle, :waiting_phases_source, fn ->
      %{session => %{last_event_at: 1_700_000_000_000, phase: "waiting"}}
    end)

    on_exit(fn -> Application.delete_env(:shuttle, :waiting_phases_source) end)

    assert {:ok, %{fibers: [%{runtime: runtime}]}} = Poller.cached_fiber_documents(poller)
    assert runtime.phase == "waiting"
    assert runtime.last_activity_at == 1_700_000_000_000

    # The escalation phase stamps straight through the same path.
    Application.put_env(:shuttle, :waiting_phases_source, fn ->
      %{session => %{last_event_at: 1_700_000_000_000, phase: "attention"}}
    end)

    assert {:ok, %{fibers: [%{runtime: escalated}]}} = Poller.cached_fiber_documents(poller)
    assert escalated.phase == "attention"

    # Clearing the activity map drops the phase but keeps last_activity_at (the
    # meta/started_at fallback) — self-healing on the serve path.
    Application.put_env(:shuttle, :waiting_phases_source, fn -> %{} end)
    assert {:ok, %{fibers: [%{runtime: cleared}]}} = Poller.cached_fiber_documents(poller)
    refute Map.has_key?(cleared, :phase)
    assert is_integer(cleared.last_activity_at)
  end

  test "owner feed omits runtime for an owned fiber with no live worker" do
    uid = "01JZ00000000000000000000RX"

    fiber =
      make_fiber("tests/idle", %{
        "uid" => uid,
        "modified_at" => "2026-06-08T01:00:00Z"
      })

    MockRunner.set_fiber("tests/idle", fiber)
    MockRunner.set_shuttle("tests/idle", "enabled: true\nkind: oneshot\nhost: candide\n")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_runtime_idle,
        runner: MockRunner,
        own_host_id: "candide",
        # No worker slots: the document caches but nothing runs, so no runtime.
        max_concurrent_workers: 0,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             get_in(Poller.snapshot(poller), [:document_cache, "entries"]) >= 1
           end)

    assert {:ok, body} = Poller.cached_fiber_documents(poller)
    assert [entry] = body.fibers
    refute Map.has_key?(entry, :runtime)
  end

  test "kill_session SIGKILLs a live worker and tears down runtime immediately, writing no status" do
    uid = "01JZ00000000000000000000KS"

    fiber =
      make_fiber("tests/killme", %{
        "uid" => uid,
        "modified_at" => "2026-06-08T01:00:00Z"
      })

    MockRunner.set_fiber("tests/killme", fiber)
    MockRunner.set_shuttle("tests/killme", "enabled: true\nkind: oneshot\nhost: candide\n")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_kill_session,
        runner: MockRunner,
        own_host_id: "candide",
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)

    # Wait until the fiber is live (stamped with runtime on the owner feed).
    assert wait_until(fn ->
             case Poller.cached_fiber_documents(poller) do
               {:ok, %{fibers: [entry]}} -> Map.has_key?(entry, :runtime)
               _ -> false
             end
           end)

    {:ok, %{fibers: [live]}} = Poller.cached_fiber_documents(poller)
    session = get_in(live, [:runtime, :tmux_session])
    assert is_binary(session)

    # Kill by fiber id — owner-routed at the controller; here we hit the Poller
    # directly. Returns the session it killed.
    assert {:ok, ^session} = Poller.kill_session(poller, "tests/killme")

    # Runtime is gone NOW — not after the watcher's next poll. The fiber's
    # document status is untouched (no awaiting-review verdict written): the
    # owner feed still serves the row, just without a runtime stamp.
    assert wait_until(fn ->
             case Poller.cached_fiber_documents(poller) do
               {:ok, %{fibers: [entry]}} -> not Map.has_key?(entry, :runtime)
               _ -> false
             end
           end)

    {:ok, %{fibers: [after_kill]}} = Poller.cached_fiber_documents(poller)
    # status untouched by the kill (the drag's column write is the verdict).
    assert get_in(after_kill, [:fiber, "status"]) in [nil, "active", "open"]

    # Idempotent: killing again when nothing runs is a clean no-op.
    assert {:ok, :no_session} = Poller.kill_session(poller, "tests/killme")
  end

  test "snapshot remains responsive while poll cycle is reading felt" do
    fiber = make_fiber("tests/slow-felt-read")
    MockRunner.set_fiber("tests/slow-felt-read", fiber)
    MockRunner.set_shuttle("tests/slow-felt-read", @oneshot_shuttle)
    MockRunner.set_felt_ls_delay(1_000)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_slow_felt_snapshot,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             Enum.any?(MockRunner.commands(), fn {cmd, args} ->
               cmd == "felt" and Enum.take(args, 2) == ["ls", "--json"]
             end)
           end)

    started_at_ms = System.monotonic_time(:millisecond)
    snap = Poller.snapshot(poller, 100)

    assert is_map(snap)
    assert System.monotonic_time(:millisecond) - started_at_ms < 100
  end

  test "poller skips closed fibers" do
    fiber = make_fiber("tests/closed", %{"status" => "closed"})
    MockRunner.set_fiber("tests/closed", fiber)
    MockRunner.set_shuttle("tests/closed", @oneshot_shuttle, "closed")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_2,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    commands = MockRunner.commands()

    refute Enum.any?(commands, fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)
  end

  test "poller skips draft fibers" do
    fiber = make_fiber("tests/draft", %{"tags" => ["constitution", "draft"], "status" => "open"})
    MockRunner.set_fiber("tests/draft", fiber)

    # Draft = shuttle block present but enabled: false; status open (not yet committed to In flight).
    MockRunner.set_shuttle("tests/draft", "enabled: false\nkind: oneshot\n", "open")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_3,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    commands = MockRunner.commands()

    refute Enum.any?(commands, fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)
  end

  test "poller auto-dispatches a LOOPING (status:active) pinned role, like a oneshot" do
    # Option D: a pinned role at status:active is LOOPING — eligible and
    # dispatched on the poll, exactly like an active oneshot. (Old model: the
    # poller hard-skipped every pinned role; the never-auto-dispatch branch is
    # gone.) The parked rest state is status:open, covered by the sibling test.
    fiber = make_fiber("tests/pinned-looping", %{"status" => "active"})
    MockRunner.set_fiber("tests/pinned-looping", fiber)
    MockRunner.set_shuttle("tests/pinned-looping", "kind: pinned\n", "active")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_pinned_looping,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             Enum.any?(MockRunner.commands(), fn {cmd, args} ->
               cmd == "tmux" and hd(args) == "new-session"
             end)
           end)

    assert Enum.any?(Poller.snapshot(poller).eligible, &(&1.fiber_id == "tests/pinned-looping"))
  end

  test "poller does NOT auto-dispatch a PARKED (status:open) pinned role" do
    # Option D: status:open is the parked rest state on the strip. The existing
    # `status != "active"` gate skips it — no bespoke pinned branch. This is the
    # park half of the loop: dragging In-flight → strip writes active → open, and
    # the role stops looping.
    fiber = make_fiber("tests/pinned-parked", %{"status" => "open"})
    MockRunner.set_fiber("tests/pinned-parked", fiber)
    MockRunner.set_shuttle("tests/pinned-parked", "kind: pinned\n", "open")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_pinned_parked,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)

    refute Enum.any?(Poller.snapshot(poller).eligible, &(&1.fiber_id == "tests/pinned-parked"))
  end

  test "a LOOPING pinned worker exit leaves the role active and re-dispatches next poll" do
    # Option D: a pinned role at status:active is looping. On worker-exit-while-
    # active it must stay status:active (NOT marked awaiting like a standing role)
    # so the next poll re-dispatches it — that's the loop. Only STANDING/cron
    # roles mark awaiting; a pinned worker that's genuinely done self-closes.
    #
    # The exit handler routes through felt (LifecycleStore → FeltStores.resolve_
    # fiber), so the mock fiber must be felt-resolvable: point LOOM_HOMES at the
    # mock store the factory wrote to (/private/tmp/.felt). Without this a
    # mark_awaiting regression would silently no-op — masking whether the gate
    # even fired.
    prev_loom = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", "/private/tmp")
    on_exit(fn -> if prev_loom, do: System.put_env("LOOM_HOMES", prev_loom), else: System.delete_env("LOOM_HOMES") end)

    fiber_id = "tests/pinned-exit-loops"
    leaf = fiber_id |> String.split("/") |> List.last()
    session = Dispatcher.session_name(fiber_id)
    MockRunner.set_fiber(fiber_id, make_fiber(fiber_id, %{"status" => "active"}))
    MockRunner.set_shuttle(fiber_id, "kind: pinned\nagent: claude-opus\n", "active")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_pinned_exit_loops,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    new_sessions = fn ->
      Enum.count(MockRunner.commands(), fn {cmd, args} ->
        cmd == "tmux" and hd(args) == "new-session" and session in args
      end)
    end

    # First dispatch (a force-dispatch is how the strip's "start" gesture fires).
    assert {:ok, _session} = Poller.dispatch_fiber(poller, fiber_id, force: true, ad_hoc: true)
    assert new_sessions.() == 1

    # Worker exits while the document is still active (it did NOT self-close).
    MockRunner.remove_tmux_session(session)
    send(poller, {:worker_exited, fiber_id, :normal_exit, false})
    # Flush the GenServer mailbox so the exit write lands before the disk read.
    _ = Poller.snapshot(poller)

    # The on-disk document is untouched: still active, never closed/awaiting.
    # Reverting the exit gate to treat pinned as cyclical flips this to closed.
    doc = File.read!("/private/tmp/.felt/#{fiber_id}/#{leaf}.md")
    assert doc =~ ~r/status:\s*active/
    refute doc =~ ~r/status:\s*closed/
    refute doc =~ "closed-at"

    # The loop: the next poll re-dispatches the still-active, no-longer-running
    # role (a SECOND new-session for the same session name).
    send(poller, :run_poll_cycle)
    assert wait_until(fn -> new_sessions.() == 2 end)
  end

  test "a standing worker exit DOES close the role to awaiting-review (status:closed)" do
    # The complement of the pinned carve-out: a STANDING (cron) worker's exit
    # still marks the role awaiting, so the cron does not re-fire it this cycle.
    # This is what guards the gate against being broadened to skip standing too.
    prev_loom = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", "/private/tmp")
    on_exit(fn -> if prev_loom, do: System.put_env("LOOM_HOMES", prev_loom), else: System.delete_env("LOOM_HOMES") end)

    fiber_id = "tests/standing-exit-closes"
    leaf = fiber_id |> String.split("/") |> List.last()
    MockRunner.set_fiber(fiber_id, make_fiber(fiber_id, %{"status" => "active"}))

    MockRunner.set_shuttle(
      fiber_id,
      """
      kind: standing
      agent: claude-sonnet
      schedule:
        expr: "0 9 * * *"
        tz: Europe/Paris
      """,
      "active"
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_exit_closes,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert {:ok, _session} = Poller.dispatch_fiber(poller, fiber_id, force: true, ad_hoc: true)

    MockRunner.remove_tmux_session(Dispatcher.session_name(fiber_id))
    send(poller, {:worker_exited, fiber_id, :normal_exit, false})
    _ = Poller.snapshot(poller)

    doc = File.read!("/private/tmp/.felt/#{fiber_id}/#{leaf}.md")
    assert doc =~ ~r/status:\s*closed/
  end

  test "poller does not dispatch a scheduled standing role before it is due" do
    fiber = make_fiber("tests/standing-sleeping", %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber("tests/standing-sleeping", fiber)

    # Slice 2: the dispatch gate is the cron schedule vs now (the stored
    # next_due_at no longer gates). A weekday-09:00 Paris schedule fires no tick
    # inside the poll window during a test run, so the role is not due. The future
    # next_due_at remains only to keep the display path (`due?`) reading
    # `scheduled`.
    MockRunner.set_shuttle(
      "tests/standing-sleeping",
      """
      enabled: true
      mode: standing
      schedule:
        kind: cron
        expr: "0 9 * * 1-5"
        timezone: Europe/Paris
      review:
        state: scheduled
      next_due_at: "2999-01-01T09:00:00+01:00"
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_sleeping,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)

    assert [%{fiber_id: "tests/standing-sleeping", state: "scheduled"}] =
             Poller.snapshot(poller).standing_roles
  end

  test "poller surfaces a standing-role snapshot from the document (no runtime store)" do
    fiber_id = "tests/standing-lifecycle-persist"
    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber(fiber_id, fiber)

    # The standing role is read straight from the document (slice 6: no runtime
    # store). Phase is the schedule-derived label; awaiting/accepted are document
    # facts (status:closed/tempered), not stored.
    MockRunner.set_shuttle(
      fiber_id,
      """
      kind: standing
      schedule:
        expr: "0 9 * * 1-5"
        tz: Europe/Paris
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_lifecycle_persist,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)

    # The schedule-derived snapshot state is scheduled or due (cron + now), never
    # a review-derived "review"/"accepted".
    assert wait_until(fn ->
             match?([%{fiber_id: ^fiber_id}], Poller.snapshot(poller).standing_roles)
           end)

    assert [%{fiber_id: ^fiber_id, state: state}] = Poller.snapshot(poller).standing_roles
    assert state in ["scheduled", "due"]
  end

  # A status:active standing role dispatches off the cron schedule, read straight
  # from the document (slice 6: no runtime overlay can wedge it). An every-minute
  # schedule is reliably due now regardless of wall-clock.
  test "a status:active standing role dispatches off the cron schedule" do
    fiber_id = "tests/standing-wedge"
    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      kind: standing
      agent: claude-sonnet
      schedule:
        expr: "* * * * *"
        tz: Europe/Paris
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_wedge,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(100)

    assert [%{fiber_id: ^fiber_id, state: "running"}] = Poller.snapshot(poller).eligible
  end

  # Awaiting is a DOCUMENT fact (status:closed + untempered), not a runtime-store
  # review row (slices 4/6). Action resolution reads the document straight — so
  # `accept-run` is available on a closed+untempered standing role (the kanban
  # "temper the weekly arXiv role" gesture re-arms it).
  test "actions reflect doc awaiting (status:closed + untempered) for a standing role" do
    fiber_id = "tests/standing-actions-overlay"
    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "standing"], "status" => "closed"})
    MockRunner.set_fiber(fiber_id, fiber)

    # The document is the authority: status:closed with no `tempered` is the
    # awaiting signal. No review block anywhere.
    MockRunner.set_shuttle(
      fiber_id,
      """
      kind: standing
      schedule:
        expr: "0 9 * * 1"
        tz: Europe/Paris
      """,
      "closed"
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_actions_overlay,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(100)

    {:ok, actions} = Poller.actions_for(poller, fiber_id, [])
    ids = Enum.map(actions, &(Map.get(&1, :id) || Map.get(&1, "id")))
    assert "accept-run" in ids

    assert {:ok, %{id: "accept-run"}} =
             Poller.resolve_action(poller, fiber_id, "tempered", [])
  end

  # Accepting a standing run through the Poller re-arms the felt document
  # (status:active, verdict cleared) and that re-arm survives the next poll —
  # there is no runtime cache to clobber it (slice 6). The document IS the truth.
  test "accept through the Poller re-arms the document and survives the next poll" do
    fiber_id = "tests/standing-accept-sticks"

    previous_loom_homes = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", "/tmp")

    on_exit(fn ->
      restore_env("LOOM_HOMES", previous_loom_homes)
    end)

    # Awaiting is a document fact (status:closed + untempered). accept re-arms it
    # from the doc schedule (status:active).
    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "standing"], "status" => "closed"})
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      kind: standing
      schedule:
        expr: "0 9 * * 1"
        tz: Europe/Paris
      """,
      "closed"
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_accept_sticks,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert {:ok, _output} = Poller.lifecycle_transition(poller, :accept, fiber_id, [])

    # The document is re-armed to status:active.
    armed = File.read!("/tmp/.felt/#{fiber_id}/standing-accept-sticks.md")
    assert armed =~ "status: active"

    send(poller, :run_poll_cycle)
    Process.sleep(75)

    # Still active after the poll — nothing clobbers the document back to awaiting.
    assert File.read!("/tmp/.felt/#{fiber_id}/standing-accept-sticks.md") =~ "status: active"
  end

  test "an accept that lands during a poll read is not clobbered when the poll completes" do
    # Regression for Symptom B of the poll-merge wedge: a standing-role `accept`
    # re-arms the felt document (status:active), but a poll Task already in flight
    # — snapshotted while the role was still the closed (awaiting) document —
    # must not revert the acceptance when it completes. The poll Task only reads;
    # the document is the single source of truth (slice 6), so the accept stands.
    fiber_id = "tests/standing-accept-during-poll"

    previous_loom_homes = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", "/tmp")

    on_exit(fn ->
      restore_env("LOOM_HOMES", previous_loom_homes)
    end)

    # Awaiting is a document fact (status:closed + untempered).
    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "standing"], "status" => "closed"})
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      kind: standing
      schedule:
        expr: "0 9 * * 1"
        tz: Europe/Paris
      """,
      "closed"
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_accept_during_poll,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    doc_path = "/tmp/.felt/#{fiber_id}/standing-accept-during-poll.md"

    # Hold the next poll inside its read-only felt walk; its snapshot still sees
    # the role as the closed (awaiting) document.
    MockRunner.set_felt_ls_delay(400)
    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             Enum.any?(MockRunner.commands(), fn {cmd, args} ->
               cmd == "felt" and Enum.take(args, 2) == ["ls", "--json"]
             end)
           end)

    # Accept while the poll is still reading (the GenServer stays responsive).
    assert {:ok, _output} = Poller.lifecycle_transition(poller, :accept, fiber_id, [])
    assert File.read!(doc_path) =~ "status: active"

    # Let the held poll complete and apply against current state.
    Process.sleep(500)

    assert File.read!(doc_path) =~ "status: active",
           "a poll completing after the accept reverted the acceptance to awaiting"
  end

  test "direct ad-hoc dispatch creates an ad-hoc standing run before the schedule is due" do
    fiber_id = "tests/standing-force-now"
    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      enabled: true
      kind: standing
      agent: claude-sonnet
      schedule:
        expr: "0 9 * * 1-5"
        tz: Europe/Paris
      review:
        state: scheduled
      next_due_at: "2999-01-01T09:00:00+01:00"
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_force_now,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Enabled standing role whose schedule is far in the future: a plain
    # dispatch is refused as not-yet-due (force/ad_hoc overrides the schedule).
    assert {:error, {:not_eligible, :not_due_or_blocked}} =
             Poller.dispatch_fiber(poller, fiber_id, [])

    assert {:ok, session} = Poller.dispatch_fiber(poller, fiber_id, force: true, ad_hoc: true)
    assert session == Dispatcher.session_name(fiber_id)

    assert [%{fiber_id: ^fiber_id, state: "running", run_id: run_id}] =
             Poller.snapshot(poller).eligible

    assert String.starts_with?(run_id, "adhoc-")

    MockRunner.remove_tmux_session(Dispatcher.session_name(fiber_id))
    send(poller, {:worker_exited, fiber_id, :normal_exit, false})
    Process.sleep(50)

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    new_session_count =
      MockRunner.commands()
      |> Enum.filter(fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)
      |> length()

    assert new_session_count == 1
  end

  test "ad-hoc dispatch refuses an awaiting standing role only when NOT forced" do
    # Awaiting is felt-native (slice 5): status:closed + untempered. The awaiting
    # gate exists to stop the *autonomous poller* (non-forced ad_hoc) from
    # re-firing a role pending a human verdict. A forced ad_hoc dispatch is the
    # human's explicit "go" from the board (New session / Resume / drag) — it IS
    # the verdict, so it bypasses the gate and spawns (re-arming the doc on the
    # way; the re-arm itself is exercised in dispatch_integration_test against a
    # real felt home). The completed timestamp comes from closed-at.
    fiber_id = "tests/standing-awaiting-refuses-adhoc"

    fiber =
      make_fiber(fiber_id, %{
        "status" => "closed",
        "closed-at" => "2026-05-24T10:00:00Z",
        "tags" => ["constitution", "standing"]
      })

    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      kind: standing
      agent: claude-sonnet
      schedule:
        expr: "0 9 * * 1-5"
        tz: Europe/Paris
      """,
      "closed"
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_awaiting_refuses_adhoc,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Non-forced ad_hoc (the poller's own path) is still refused with the
    # awaiting marker, and never spawns.
    assert {:error, {:awaiting_review, nil, "2026-05-24T10:00:00Z"}} =
             Poller.dispatch_fiber(poller, fiber_id, ad_hoc: true)

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)

    # Forced ad_hoc (the human board action) bypasses the gate and spawns.
    assert {:ok, _session} = Poller.dispatch_fiber(poller, fiber_id, force: true, ad_hoc: true)

    assert Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)
  end

  test "actions/resolve read tmux-live running state, not a stale registry hit" do
    # C1-adjacent: :dispatch reconciles against tmux before reading state.running,
    # but :actions and :resolve_action used to read the registry raw. So in the
    # window after a worker's session dies (before the poll tick reconciles), a
    # drag→inFlight resolved to `pause` for a worker that no longer exists — and
    # invoke (which reconciles) then 409s. The read legs now derive `running?`
    # from a live tmux check (`live_running?`), matching the dispatch leg —
    # without the eviction side effects (those stay on the poll/dispatch path).
    fiber_id = "tests/reconcile-dead-session"
    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_reconcile_dead_session,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Let the initial poll auto-dispatch the eligible fiber and settle, so the
    # worker is in state.running and no further poll cycle is queued behind the
    # read legs below. (Driving dispatch via `force:` here instead would race
    # the initial poll's reconcile, which — landing after the kill — would
    # re-dispatch the fiber and re-create a live session.)
    session = Dispatcher.session_name(fiber_id)
    assert wait_until(fn -> Poller.worker_status(poller, fiber_id) != nil end)

    # While the session is live, the running branch is read: inFlight → pause.
    assert {:ok, %{id: "pause"}} = Poller.resolve_action(poller, fiber_id, "inFlight", [])

    # Kill the tmux session WITHOUT a poll tick or :worker_exited message.
    MockRunner.remove_tmux_session(session)

    # The read legs now see the session is gone (live tmux check), so the fiber
    # reads idle and inFlight resolves to a fresh dispatch (not pause). The
    # discriminator is the inFlight resolution — `pause` is in the idle
    # availability set too (drafts→pause), so we assert on resolve, not the set.
    assert {:ok, %{id: "dispatch-ad-hoc"}} =
             Poller.resolve_action(poller, fiber_id, "inFlight", [])

    {:ok, actions} = Poller.actions_for(poller, fiber_id, [])
    ids = Enum.map(actions, &(Map.get(&1, :id) || Map.get(&1, "id")))
    assert "dispatch-ad-hoc" in ids
  end

  test "forced non-ad-hoc standing dispatch keeps scheduled run context for resume" do
    fiber_id = "tests/standing-force-scheduled"
    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      enabled: true
      kind: standing
      agent: claude-sonnet
      schedule:
        expr: "0 9 * * 1-5"
        tz: Europe/Paris
      review:
        state: scheduled
      next_due_at: "2999-01-01T09:00:00+01:00"
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_force_scheduled,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert {:ok, _session} = Poller.dispatch_fiber(poller, fiber_id, force: true)

    assert [%{fiber_id: ^fiber_id, state: "running", run_id: run_id}] =
             Poller.snapshot(poller).eligible

    refute String.starts_with?(run_id, "adhoc-")
    assert String.starts_with?(run_id, "29990101T080000")
  end

  test "forced standing dispatch honors just-filed resume intent before next scheduled window" do
    fiber_id = "tests/standing-force-resume-before-window"
    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      kind: standing
      agent: claude-sonnet
      schedule:
        expr: "0 9 * * 1-5"
        tz: Europe/Paris
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_force_resume_before_window,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # The prior run's session id lives in felt history (slice 6); a forced resume
    # parses it back via extract_session_id. The resume directive post-dates it.
    append_dispatch_session(fiber_id, "stored-standing-session-id")
    append_review_comment(fiber_id, resume_mode: "previous")

    assert {:ok, _session} = Poller.dispatch_fiber(poller, fiber_id, force: true)

    script_path = new_session_scripts() |> List.last()
    assert script_path, "expected at least one new-session script"
    script = File.read!(script_path)

    assert script =~ "--resume"
    assert script =~ "stored-standing-session-id"
  end

  test "force-dispatch runs a closed fiber while leaving its status untouched" do
    # Manual "New session" / "Resume" buttons on a closed kanban card must
    # spawn a worker even though the fiber is closed (composted/tempered).
    # The Poller's force path bypasses the status check; the Dispatcher's
    # check_not_closed honors `force: true`. Status itself is *not* reopened
    # — closed fibers stay closed; the worker just runs against the current
    # outcome.
    fiber_id = "tests/closed-force"
    fiber = make_fiber(fiber_id, %{"status" => "closed"})
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      "enabled: true\nkind: oneshot\nagent: claude-sonnet\n",
      "closed"
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_force_closed,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Without force, a closed fiber is not eligible — and the reason now names
    # the cause (closed) so the kanban can say "reopen it first".
    assert {:error, {:not_eligible, :closed}} = Poller.dispatch_fiber(poller, fiber_id, [])
    # With force, the same fiber dispatches.
    assert {:ok, session} = Poller.dispatch_fiber(poller, fiber_id, force: true)
    assert session == Dispatcher.session_name(fiber_id)
  end

  test "force-dispatch runs a draft fiber (status: open)" do
    # A draft (status: open) is not auto-dispatched (slice 5: status is the sole
    # gate, no enabled flag) but is still available for explicit manual launch —
    # the click is the override.
    fiber_id = "tests/disabled-force"
    fiber = make_fiber(fiber_id, %{"status" => "open"})
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, "kind: oneshot\nagent: claude-sonnet\n", "open")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_force_disabled,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert {:error, {:not_eligible, :disabled}} = Poller.dispatch_fiber(poller, fiber_id, [])
    assert {:ok, _session} = Poller.dispatch_fiber(poller, fiber_id, force: true)
  end

  test "force-dispatch still refuses fibers pinned to a different host" do
    # Host is a real hardware constraint — we can't conjure a worker on
    # another machine. Force relaxes intent, not topology.
    fiber_id = "tests/wrong-host-force"
    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      "enabled: true\nkind: oneshot\nagent: claude-sonnet\nhost: some-other-machine\n"
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_force_wrong_host,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # The refusal now NAMES the cause: the fiber is homed elsewhere, carrying
    # both its declared host and this daemon's own id. The kanban surfaces this
    # as "homed on <host>, can only run there" instead of the misleading
    # "disabled, not yet due, or closed" — the Bug-3 fix.
    assert {:error, {:not_eligible, {:homed_elsewhere, "some-other-machine", "test-host"}}} =
             Poller.dispatch_fiber(poller, fiber_id, force: true)
  end

  test "force-dispatch still refuses human-worker fibers" do
    # Human-worker fibers have no machine to spawn against. Even under
    # force, dispatch is a no-op (success without a tmux session).
    fiber_id = "tests/human-worker-force"
    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, "enabled: true\nkind: oneshot\nagent: human\n")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_force_human,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Human-worker fibers short-circuit to {:ok, "human"} before the
    # eligibility check runs (the API does not start a tmux session for
    # them); force does not change that.
    assert {:ok, "human"} = Poller.dispatch_fiber(poller, fiber_id, force: true)
  end

  test "poller dispatches a due standing role with run context and does not hot-loop after exit" do
    # Uses new-format "kind: standing" (vs legacy "mode: standing") to test backward compat.
    fiber = make_fiber("tests/standing-due", %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber("tests/standing-due", fiber)

    # Slice 2: due-ness is computed from the cron schedule + now, not a stored
    # next_due_at. `* * * * *` fires every minute, so a tick always lands inside
    # the poll window → the role is due now, deterministically.
    MockRunner.set_shuttle(
      "tests/standing-due",
      """
      enabled: true
      kind: standing
      agent: claude-sonnet
      schedule:
        expr: "* * * * *"
        tz: Europe/Paris
      review:
        state: scheduled
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_due,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(100)

    assert [%{fiber_id: "tests/standing-due", state: "running", run_id: run_id}] =
             Poller.snapshot(poller).eligible

    assert is_binary(run_id)

    # Simulate the worker exit. In production the exit handler's standing branch
    # writes status:closed to the felt document (mark_standing_awaiting) BEFORE it
    # releases the claim, so no poll after the exit ever sees the role armed. The
    # MockRunner's `felt ls` reads its in-memory map, not the on-disk write
    # mark_awaiting performs, so mirror that document close here — atomically with
    # the exit — to reproduce the production ordering. With an every-minute cron,
    # this closed-state is the ONLY thing preventing immediate re-dispatch (slice
    # 2 dropped the completed_standing_runs MapSet): the `active → closed → active`
    # document transition is the sole per-cycle gate.
    MockRunner.set_shuttle(
      "tests/standing-due",
      """
      enabled: true
      kind: standing
      agent: claude-sonnet
      schedule:
        expr: "* * * * *"
        tz: Europe/Paris
      """,
      "closed"
    )

    MockRunner.remove_tmux_session(Dispatcher.session_name("tests/standing-due"))
    send(poller, {:worker_exited, "tests/standing-due", :normal_exit, false})
    Process.sleep(50)

    refute Enum.any?(Poller.snapshot(poller).retrying, &(&1.fiber_id == "tests/standing-due"))

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    new_session_count =
      MockRunner.commands()
      |> Enum.filter(fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)
      |> length()

    assert new_session_count == 1

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "felt" and Enum.take(args, 2) == ["standing", "review"]
           end)
  end

  # Slice 4: a stale stored next_due_at no longer fires the role — due-ness is
  # cron-computed against the poll window (the morning-post-drift rule). A role
  # whose only past tick fell outside the window is not dispatched, and its
  # snapshot is a valid schedule-derived state (no review/accepted validation).
  test "poller does not dispatch a standing role whose stored next_due is stale" do
    fiber = make_fiber("tests/standing-stale", %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber("tests/standing-stale", fiber)

    MockRunner.set_shuttle(
      "tests/standing-stale",
      """
      enabled: true
      mode: standing
      schedule:
        kind: cron
        expr: "0 9 * * 1-5"
        timezone: Europe/Paris
      next_due_at: "2000-01-03T09:00:00+01:00"
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_stale,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)

    assert [%{fiber_id: "tests/standing-stale", state: state, validation_errors: []}] =
             Poller.snapshot(poller).standing_roles

    assert state in ["scheduled", "due"]
  end

  # Slice 4: the snapshot state is schedule-derived (scheduled/due/dormant/
  # running), never a review-derived "review"/"accepted". Awaiting/accepted are
  # document facts the kanban classifier reads from status/tempered.
  test "snapshot standing state is schedule-derived, not review-derived" do
    sleeping = make_fiber("tests/standing-review", %{"tags" => ["constitution", "standing"]})

    paused =
      make_fiber("tests/standing-accepted", %{
        "status" => "open",
        "tags" => ["constitution", "standing"]
      })

    MockRunner.set_fiber("tests/standing-review", sleeping)
    MockRunner.set_fiber("tests/standing-accepted", paused)

    # A leftover review block is ignored (slice 5: no review axis); the role reads
    # scheduled (its next weekday-09:00 tick is in the future).
    MockRunner.set_shuttle(
      "tests/standing-review",
      """
      mode: standing
      schedule:
        kind: cron
        expr: "0 9 * * 1-5"
        timezone: Europe/Paris
      """
    )

    # A draft role (status: open) still reads scheduled in the schedule-derived
    # snapshot — paused/draft is a document fact (status), surfaced by the kanban
    # classifier from the document, not a StandingRole phase (slice 5).
    MockRunner.set_shuttle(
      "tests/standing-accepted",
      """
      mode: standing
      schedule:
        kind: cron
        expr: "0 9 * * 1-5"
        timezone: Europe/Paris
      """,
      "open"
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_snapshot_states,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             length(Poller.snapshot(poller).standing_roles) == 2
           end)

    roles = Poller.snapshot(poller).standing_roles
    assert Enum.find(roles, &(&1.fiber_id == "tests/standing-review")).state == "scheduled"
    assert Enum.find(roles, &(&1.fiber_id == "tests/standing-accepted")).state == "scheduled"
  end

  test "poller respects dependency satisfaction" do
    dep = make_fiber("tests/dep", %{"tempered" => false, "tags" => []})
    fiber = make_fiber("tests/dependent", %{"depends_on" => ["tests/dep"]})

    MockRunner.set_fiber("tests/dependent", fiber)
    MockRunner.set_fiber("tests/dep", dep)
    MockRunner.set_shuttle("tests/dependent", @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_4,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    commands = MockRunner.commands()

    refute Enum.any?(commands, fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session" and
               Enum.member?(args, Dispatcher.session_name("tests/dependent"))
           end)
  end

  test "poller skips untracked fibers" do
    fiber = make_fiber("tests/untracked", %{"status" => "untracked"})
    MockRunner.set_fiber("tests/untracked", fiber)
    MockRunner.set_shuttle("tests/untracked", @oneshot_shuttle, "untracked")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_untracked,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    commands = MockRunner.commands()

    refute Enum.any?(commands, fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)
  end

  test "poller dispatches when dependencies are tempered" do
    dep = make_fiber("tests/dep", %{"tempered" => true})
    fiber = make_fiber("tests/dependent", %{"depends_on" => [%{"id" => "tests/dep"}]})

    MockRunner.set_fiber("tests/dependent", fiber)
    MockRunner.set_fiber("tests/dep", dep)
    MockRunner.set_shuttle("tests/dependent", @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_5,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(100)

    commands = MockRunner.commands()

    assert Enum.any?(commands, fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)
  end

  test "poller does not double-dispatch" do
    fiber = make_fiber("tests/haiku-dedup")
    MockRunner.set_fiber("tests/haiku-dedup", fiber)
    MockRunner.set_shuttle("tests/haiku-dedup", @oneshot_shuttle)
    MockRunner.add_tmux_session(Dispatcher.session_name("tests/haiku-dedup"))

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_6,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    # Should not create a new session
    new_session_count =
      MockRunner.commands()
      |> Enum.filter(fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)
      |> length()

    assert new_session_count == 0
  end

  test "poller re-dispatches a still-active oneshot after its worker exits (retry collapsed into poll loop)" do
    # Retries collapsed into the poll loop (slice 6): when a multi-session
    # oneshot worker exits but its document is still status:active, the claim is
    # released and the next poll re-picks it (status:active + no live session →
    # eligible) and starts a fresh session.
    fiber = make_fiber("tests/haiku-retry")
    MockRunner.set_fiber("tests/haiku-retry", fiber)
    MockRunner.set_shuttle("tests/haiku-retry", @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_7,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Dispatch
    send(poller, :run_poll_cycle)
    Process.sleep(100)

    snap1 = Poller.snapshot(poller)
    assert length(snap1.eligible) == 1

    # Simulate worker exit (tmux session dies). The claim is released; the fiber
    # is no longer running and no longer retrying (the retry queue is gone).
    MockRunner.remove_tmux_session(Dispatcher.session_name("tests/haiku-retry"))
    send(poller, {:worker_exited, "tests/haiku-retry", :normal_exit, false})
    Process.sleep(50)

    snap2 = Poller.snapshot(poller)
    assert length(snap2.eligible) == 0
    assert snap2.retrying == []

    # The next poll re-dispatches it: a second new-session call.
    send(poller, :run_poll_cycle)

    assert wait_until(
             fn ->
               MockRunner.commands()
               |> Enum.count(fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)
               |> Kernel.==(2)
             end,
             80
           )
  end

  test "running snapshot keys the in-memory registry and rows by intrinsic uid" do
    fiber_id = "tests/running-uid-keyed"
    uid = "01KTCA2CWXBSNHETE66MXKPVE7"

    fiber = make_fiber(fiber_id, %{"uid" => uid})
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_running_uid_keyed,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert {:ok, _session} = Poller.dispatch_fiber(poller, fiber_id, [])

    # The in-memory running registry is keyed by uid (slice 3/6).
    state = :sys.get_state(poller)
    assert Map.has_key?(state.running, uid)
    refute Map.has_key?(state.running, fiber_id)

    # Slice 7: no separate `:runtime` index. The live worker rides the
    # `eligible` row, which carries both the intrinsic uid (the join key) and the
    # felt address (the display/CLI handle).
    snap = Poller.snapshot(poller)
    refute Map.has_key?(snap, :runtime)

    assert [%{fiber_id: ^fiber_id, uid: ^uid, state: "running"}] = snap.eligible
  end

  test "force-dispatch honors resume_mode: previous review-comment (unified resume path)" do
    # The old kanban-modal flow had two separate paths: "New session"
    # (ad-hoc, force-fresh) and "Resume" (a special accept-then-dispatch
    # dance via shuttle-ctl resume). Under unified force semantics, BOTH
    # buttons file a review-comment carrying resume_mode and dispatch with
    # force: true. resolve_resume_intent honors the latest
    # review-comment regardless of dispatch context (oneshot, standing
    # scheduled, standing ad-hoc).
    fiber_id = "tests/force-resume-unified"
    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      kind: oneshot
      agent: claude-sonnet
      """
    )

    # Record the prior session id in felt history (the dispatcher writes a
    # "worker dispatched ... session=<uuid>" event at spawn; slice 6: felt
    # history is the only durable session-id home), and file the resume directive
    # BEFORE the poller starts so its first poll dispatches the resume.
    append_dispatch_session(fiber_id, "stored-session-id")
    append_review_comment(fiber_id, resume_mode: "previous")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_force_resume_unified,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Whether the resume comes from the auto-poll or the explicit force-dispatch,
    # the dispatch produces a --resume invocation against the history session id,
    # not a fresh new-session.
    _ = Poller.dispatch_fiber(poller, fiber_id, force: true)

    assert wait_until(fn -> new_session_scripts() != [] end)

    script = new_session_scripts() |> List.last() |> File.read!()

    assert script =~ "--resume"
    assert script =~ "stored-session-id"
  end

  test "poller continuation re-dispatches fresh when no resume directive is on file" do
    # Retries collapsed into the poll loop (slice 6). A multi-session oneshot's
    # autonomous continuation re-dispatches through the normal poll path; with no
    # `resume_mode: previous` review-comment on file, the dispatch is fresh — it
    # does not resume a prior session UUID.
    fiber_id = "tests/continuation-fresh"

    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      kind: oneshot
      agent: claude-sonnet
      """
    )

    # A prior session id exists in felt history, but no resume directive — so the
    # autonomous re-dispatch must NOT resume it.
    append_dispatch_session(fiber_id, "old-session-id")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_continuation_fresh,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    assert wait_until(fn -> length(new_session_scripts()) == 1 end, 80)

    MockRunner.remove_tmux_session(Dispatcher.session_name(fiber_id))
    send(poller, {:worker_exited, fiber_id, :normal_exit, false})

    # Next poll re-dispatches the still-active oneshot.
    send(poller, :run_poll_cycle)
    assert wait_until(fn -> length(new_session_scripts()) == 2 end, 80)

    second_script = new_session_scripts() |> List.last() |> File.read!()
    assert second_script =~ "Fiber: #{fiber_id}"
    refute second_script =~ "--resume"
    refute second_script =~ "old-session-id"
  end

  test "poller releases claim when worker exits and fiber is closed" do
    # Use a fiber ID unique to this test — shared names (like "tests/haiku") can
    # collide with sessions left over from other tests' Pollers/Watchers.
    fiber = make_fiber("tests/haiku-close")
    MockRunner.set_fiber("tests/haiku-close", fiber)
    MockRunner.set_shuttle("tests/haiku-close", @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_8,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Dispatch
    send(poller, :run_poll_cycle)
    Process.sleep(100)

    # Close the fiber
    MockRunner.set_fiber("tests/haiku-close", %{fiber | "status" => "closed"})
    MockRunner.remove_tmux_session(Dispatcher.session_name("tests/haiku-close"))
    send(poller, {:worker_exited, "tests/haiku-close", :normal_exit, false})
    Process.sleep(50)

    snap = Poller.snapshot(poller)
    assert snap.claimed_count == 0
    assert length(snap.retrying) == 0
  end

  test "poller adopts orphan tmux sessions on startup" do
    MockRunner.set_shuttle("tests/orphan", @oneshot_shuttle)
    MockRunner.add_tmux_session(Dispatcher.session_name("tests/orphan"))

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_9,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    Process.sleep(100)

    snap = Poller.snapshot(poller)
    assert length(snap.eligible) == 1
    assert hd(snap.eligible).fiber_id == "tests/orphan"
  end

  test "poller adopts a uid-carrying fiber's worker under the new uid-keyed session" do
    fiber_id = "tests/orphan-uid"
    uid = "01KTHDNZS287ZSSG8X8V59XKWB"
    MockRunner.set_fiber(fiber_id, make_fiber(fiber_id, %{"uid" => uid}))
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)
    MockRunner.add_tmux_session(Dispatcher.session_name(fiber_id, uid))

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_orphan_uid,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    Process.sleep(100)

    snap = Poller.snapshot(poller)
    assert Enum.any?(snap.eligible, &(&1.fiber_id == fiber_id and &1.state == "running"))
  end

  test "poller adopts a uid-carrying fiber's LEGACY-named worker (dual-recognition)" do
    # A worker launched before the uid-keyed cutover is live under the legacy
    # leaf-only name. The owning daemon must still recognize and adopt it after
    # an upgrade, so the deploy order is safe and live legacy workers aren't
    # abandoned.
    fiber_id = "tests/orphan-legacy"
    uid = "01KTHDNZS287ZSSG8X8V59XKWC"
    MockRunner.set_fiber(fiber_id, make_fiber(fiber_id, %{"uid" => uid}))
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)
    # Live session carries the LEGACY name, not the uid-keyed one.
    MockRunner.add_tmux_session(Dispatcher.session_name(fiber_id))

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_orphan_legacy,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    Process.sleep(100)

    snap = Poller.snapshot(poller)
    assert Enum.any?(snap.eligible, &(&1.fiber_id == fiber_id and &1.state == "running"))
  end

  test "poller adopts a live orphan session for a looping pinned role (no duplicate dispatch)" do
    # Regression for the daemon-restart-drops-all-adoptions bug. After a restart,
    # `candidate_session_lookup` must record the fiber_id for a session name seen
    # exactly once — every uid-keyed name is unique to one fiber. A `Map.update/4`
    # misuse inserted the default grouped sets VERBATIM (the update fun is not
    # applied to the default), so a single-occurrence session kept empty sets,
    # resolved to nil, and the live worker was never adopted.
    #
    # A looping pinned role (Option D: status:active dispatches) with a live
    # worker must be adopted as running — NOT duplicate-dispatched by the loop —
    # whether via `candidate_session_lookup` or the dispatch→:already_running
    # adopt. The field symptom this guards: operator/morning-post showing at-rest
    # on the board while a live worker existed.
    fiber_id = "tests/pinned-orphan"
    uid = "01KTHDNZS287ZSSG8X8V59XKWD"
    MockRunner.set_fiber(fiber_id, make_fiber(fiber_id, %{"uid" => uid, "status" => "active"}))
    MockRunner.set_shuttle(fiber_id, "kind: pinned\n", "active")
    MockRunner.add_tmux_session(Dispatcher.session_name(fiber_id, uid))

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_pinned_orphan,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    Process.sleep(100)

    snap = Poller.snapshot(poller)

    assert Enum.any?(snap.eligible, &(&1.fiber_id == fiber_id and &1.state == "running")),
           "a resting pinned role with a live orphan session must be adopted as running"
  end

  # Retries collapsed into the poll loop (slice 6): a status:active oneshot whose
  # worker died while the daemon was down has no live tmux session, so it is
  # simply eligible again — the next poll re-dispatches it. There is no separate
  # "resurrection" path or retry row to assert; the contract is that a fresh
  # session is spawned.
  test "poller re-dispatches a status:active oneshot whose worker died while the daemon was down" do
    fiber_id = "tests/orphan-dispatched-dead"

    MockRunner.set_shuttle(fiber_id, """
    kind: oneshot
    agent: claude-sonnet
    """)

    # A prior dispatch is recorded in felt history but no tmux session is alive.
    append_dispatch_session(fiber_id, "577af64b-644a-4733-9e6a-f60d86b6941f")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_resurrect_orphan,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert wait_until(fn ->
             Enum.any?(MockRunner.commands(), fn {cmd, args} ->
               cmd == "tmux" and hd(args) == "new-session"
             end)
           end)

    assert Enum.any?(Poller.snapshot(poller).eligible, &(&1.fiber_id == fiber_id))
  end

  # Regression for the 2026-05-30 incident: a cineca/candide restart resurrected
  # Mac-owned Portolan constitutions locally because the orphan path never read
  # `host`. The poll path uses the strict ownership predicate — a fiber owned by
  # another host is never dispatched here.
  test "poller does not dispatch a foreign-host oneshot whose worker is dead" do
    fiber_id = "tests/orphan-foreign-host"

    MockRunner.set_shuttle(fiber_id, """
    kind: oneshot
    host: some-other-machine
    """)

    append_dispatch_session(fiber_id, "577af64b-644a-4733-9e6a-f60d86b6941f")

    # own_host_id is the default "test-host", which does not equal
    # "some-other-machine".
    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_resurrect_foreign_host,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(150)

    snap = Poller.snapshot(poller)
    assert snap.claimed_count == 0

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)
  end

  # The project_dir disqualifier applies to the poll path: a checkout that does
  # not exist on this host means the worker can't run here, owned or not.
  test "poller does not dispatch an active oneshot whose declared project_dir is missing" do
    fiber_id = "tests/orphan-missing-project-dir"

    MockRunner.set_shuttle(fiber_id, """
    kind: oneshot
    host: test-host
    project_dir: /nonexistent/path/shuttle-orphan-missing
    """)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_resurrect_missing_project_dir,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(150)

    snap = Poller.snapshot(poller)
    assert snap.eligible == []
    assert snap.claimed_count == 0

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)
  end

  # The poll path: an absent host: is unowned everywhere (no nil-wildcard).
  # This is the failure mode that, before the cutover, made the wrong daemon
  # grab single-host work. Distinct from the wrong-host case (host present but
  # mismatched) — here host is structurally absent.
  test "poller treats a host-less fiber as ineligible (absent host is unowned)" do
    fiber_id = "tests/host-absent"

    # Write the .md file directly (discovery walks files), bypassing the
    # factory's host injection so the block genuinely has no host: key —
    # exercising the literal "absent host" branch. The fiber is discovered
    # (it carries a shuttle block) but unowned, hence ineligible everywhere.
    dir_path = Path.join(["/tmp/.felt", fiber_id <> ".md"])
    File.mkdir_p!(Path.dirname(dir_path))

    File.write!(dir_path, """
    ---
    status: active
    shuttle:
      enabled: true
      kind: oneshot
      agent: claude-sonnet
    ---
    body
    """)

    fiber = make_fiber(fiber_id)

    MockRunner.set_fiber(
      fiber_id,
      Map.put(fiber, "shuttle", %{
        "enabled" => true,
        "kind" => "oneshot",
        "agent" => "claude-sonnet"
      })
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_host_absent,
        runner: MockRunner,
        own_host_id: "test-host",
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(50)

    snap = Poller.snapshot(poller)
    assert snap.eligible == []
    assert snap.claimed_count == 0

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)
  after
    File.rm_rf!(Path.join(["/tmp/.felt", "tests/host-absent.md"]))
  end

  test "poller marks an armed standing role awaiting when its worker died while the daemon was down" do
    # Slice 6 dead-orphan handling on the tmux-scan substrate: a standing role
    # whose document is armed (status:active, no verdict) but whose tmux session
    # is gone never fired handle_worker_exit (daemon was down across the exit), so
    # the poll-scan marks it awaiting (status:closed) — never re-dispatched, never
    # re-fired off the schedule mid-cycle.
    fiber_id = "tests/standing-dead-orphan"

    previous_loom_homes = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", "/tmp")
    on_exit(fn -> restore_env("LOOM_HOMES", previous_loom_homes) end)

    # A far-future schedule so the role is NOT cron-due — the only thing that
    # could touch it is the dead-orphan marker, not a scheduled dispatch.
    MockRunner.set_shuttle(fiber_id, """
    kind: standing
    agent: claude-sonnet
    schedule:
      expr: "0 9 1 1 *"
      tz: Europe/Paris
    """)

    # The felt-history discriminator: a trailing "worker dispatched" event with no
    # "worker exited" after it marks this as a daemon-down-across-exit dead orphan.
    append_dispatch_session(fiber_id, "dead-session-uuid")

    doc_path = "/tmp/.felt/#{fiber_id}/standing-dead-orphan.md"

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_dead_orphan,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)

    assert wait_until(fn -> File.read!(doc_path) =~ "status: closed" end, 80)

    # No worker was spawned — the role was marked awaiting, not dispatched.
    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)
  end

  test "poller does not re-dispatch a closed oneshot whose worker is dead" do
    fiber_id = "tests/closed-with-session"

    MockRunner.set_shuttle(
      fiber_id,
      """
      kind: oneshot
      agent: claude-sonnet
      """,
      "closed"
    )

    append_dispatch_session(fiber_id, "closed-uuid")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_closed_not_resurrected,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(150)

    # Closed is the don't-re-fire gate: no new session is spawned.
    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)
  end

  test "poller clears stale running state when the tmux session disappears" do
    fiber_id = "tests/missing-running-session"

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_missing_running_session,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)

    assert {:ok, session} = Poller.dispatch_fiber(poller, fiber_id, [])
    assert session == Dispatcher.session_name(fiber_id)

    MockRunner.remove_tmux_session(session)
    send(poller, :run_poll_cycle)

    # The poll must clear the dead-session running entry, record it as an
    # orphan, and recover the fiber by re-dispatching it. Whether the fiber is
    # *currently* in `running` is a transient: the watcher for the now-dead
    # session fires a late `{:worker_exited}` that flips it toward a retry, and
    # the retry re-dispatches again — so "running right now" flaps on watcher
    # timing. The stable invariants are the orphan record and that a second
    # dispatch happened, so assert those instead of catching the flap.
    assert wait_until(
             fn ->
               snap = Poller.snapshot(poller)

               new_session_count =
                 MockRunner.commands()
                 |> Enum.count(fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)

               Enum.any?(snap.orphans, &(&1.fiber_id == fiber_id)) and new_session_count >= 2
             end,
             80
           )

    snap = Poller.snapshot(poller)

    assert [
             %{
               fiber_id: ^fiber_id,
               tmux_session: ^session,
               reason: "missing_tmux_session"
             }
             | _
           ] = snap.orphans
  end

  test "poller re-adopts a live tmux worker on restart (running is tmux-derived)" do
    # Daemon state is derived and disposable (slice 6: no runtime store). After a
    # restart the live tmux session is re-adopted by adopt_orphans, so the worker
    # is tracked again — running work survives because tmux owns the process.
    fiber_id = "tests/runtime-rehydrate-live"

    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_runtime_rehydrate_live_1,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert {:ok, session} = Poller.dispatch_fiber(poller, fiber_id, [])
    assert Enum.any?(Poller.snapshot(poller).eligible, &(&1.fiber_id == fiber_id))

    GenServer.stop(poller)

    # The tmux session is still alive (the MockRunner tracks it across the
    # GenServer restart) — the restarted poller re-adopts it from the tmux scan.
    {:ok, restarted} =
      Poller.start_link(
        name: :test_poller_runtime_rehydrate_live_2,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert wait_until(fn ->
             Poller.snapshot(restarted).eligible
             |> Enum.any?(&(&1.fiber_id == fiber_id and &1.tmux_session == session))
           end)
  end

  test "poller does not track a worker whose tmux session disappeared while daemon was down" do
    # No runtime store to rehydrate from (slice 6): a restart re-scans tmux, and
    # a dead session is simply absent — nothing is tracked as running, and the
    # still-active fiber is re-dispatched fresh on the next poll.
    fiber_id = "tests/runtime-rehydrate-missing"

    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_runtime_rehydrate_missing_1,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert {:ok, session} = Poller.dispatch_fiber(poller, fiber_id, [])

    GenServer.stop(poller)
    MockRunner.remove_tmux_session(session)

    {:ok, restarted} =
      Poller.start_link(
        name: :test_poller_runtime_rehydrate_missing_2,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # The dead session is not adopted: the restarted poller has no running entry
    # for this fiber.
    state = :sys.get_state(restarted)
    refute Map.has_key?(state.running, fiber_id)
    refute Enum.any?(state.running, fn {_k, m} -> Map.get(m, :fiber_id) == fiber_id end)
  end

  test "poller clears stale parent running state when only a child session exists" do
    fiber_id = "tests/prefix-parent"

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_prefix_parent,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)

    assert {:ok, session} = Poller.dispatch_fiber(poller, fiber_id, [])
    MockRunner.remove_tmux_session(session)
    MockRunner.add_tmux_session(session <> "/child")

    assert {:ok, ^session} = Poller.dispatch_fiber(poller, fiber_id, [])

    assert Enum.any?(MockRunner.commands(), fn
             {"tmux", ["has-session", "-t", target]} -> target == "=" <> session
             _ -> false
           end)
  end

  test "poller uses shuttle.project_dir as work_dir when it exists" do
    project_dir =
      Path.join(System.tmp_dir!(), "shuttle-test-proj-#{System.unique_integer([:positive])}")

    File.mkdir_p!(project_dir)

    fiber = make_fiber("tests/project-dir-fiber")
    MockRunner.set_fiber("tests/project-dir-fiber", fiber)

    MockRunner.set_shuttle("tests/project-dir-fiber", """
    enabled: true
    kind: oneshot
    project_dir: #{project_dir}
    """)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_project_dir,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(100)

    # tmux args: ["new-session", "-d", "-s", session, "-c", work_dir, "bash", "-l", script]
    # work_dir is at index 5
    {_, args} =
      Enum.find(MockRunner.commands(), fn {cmd, args} ->
        cmd == "tmux" and hd(args) == "new-session"
      end)

    assert Enum.at(args, 5) == project_dir
  after
    File.rm_rf(Path.join(System.tmp_dir!(), "shuttle-test-proj-*"))
  end

  test "poller disqualifies (does not downgrade) a fiber whose declared project_dir is missing" do
    # A declared project_dir absent on this host means the checkout lives on
    # another machine. The pre-cutover behavior downgraded the worker cwd to a
    # felt store and dispatched anyway (native-desktop misdispatch root cause
    # #2); the cutover makes it *ineligible* — disqualify, don't downgrade.
    # host: test-host matches so the only disqualifier under test is the dir.
    fiber = make_fiber("tests/missing-project-dir")
    MockRunner.set_fiber("tests/missing-project-dir", fiber)

    MockRunner.set_shuttle("tests/missing-project-dir", """
    enabled: true
    kind: oneshot
    host: test-host
    project_dir: /nonexistent/path/shuttle-test-missing
    """)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_missing_project_dir,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)
    Process.sleep(100)

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)

    assert Poller.snapshot(poller).eligible == []
  end

  test "poller adopts orphan sessions with literal hyphenated fiber ids" do
    fiber_id = "ai-futures/shuttle/constitution-shuttle-standalone"
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)
    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "codex"]})

    MockRunner.set_fiber(
      fiber_id,
      Map.put(fiber, "shuttle", %{
        "enabled" => true,
        "kind" => "oneshot",
        "agent" => "claude-sonnet",
        "host" => "test-host"
      })
    )

    MockRunner.add_tmux_session(Dispatcher.session_name(fiber_id))

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_10,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    Process.sleep(100)

    snap = Poller.snapshot(poller)
    assert [%{fiber_id: ^fiber_id, tmux_session: session}] = snap.eligible
    assert session == Dispatcher.session_name(fiber_id)
  end

  # Regression: a fiber with a shuttle: block but *no* constitution tag must be
  # discovered and dispatched. This is the core invariant from the cutover —
  # the block is the source of truth, not the tag.
  test "poller discovers and dispatches a fiber with shuttle block but no constitution tag" do
    fiber_id = "tests/untagged-shuttle"
    fiber = make_fiber(fiber_id, %{"tags" => []})
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_untagged_shuttle,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, {:tick, Poller.snapshot(poller) |> Map.get(:tick_token)})

    assert wait_until(fn ->
             Enum.any?(MockRunner.commands(), fn {cmd, args} ->
               cmd == "tmux" and hd(args) == "new-session"
             end)
           end)

    assert wait_until(fn ->
             Poller.snapshot(poller).eligible
             |> Enum.any?(&(&1.fiber_id == fiber_id))
           end)
  end

  test "dispatch_fiber waits past the default GenServer timeout for slow successful dispatches" do
    fiber_id = "tests/slow-api-dispatch"
    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)
    MockRunner.set_new_session_delay(5_250)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_slow_dispatch,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    started_at_ms = System.monotonic_time(:millisecond)

    assert {:ok, session} = Poller.dispatch_fiber(poller, fiber_id, [])

    elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms
    assert elapsed_ms >= 5_000
    assert session == Dispatcher.session_name(fiber_id)
    assert Poller.snapshot(poller).eligible |> Enum.any?(&(&1.fiber_id == fiber_id))
  end

  # ── Multi-host tests ──
  #
  # These tests exercise the multi-felt-store path directly against the file
  # system; they bypass MockRunner's in-memory fiber store and write real
  # .felt/ directories instead. They use `resolve_fiber_host/2` (the public
  # GenServer call) to verify host_for_fiber resolution without depending on
  # dispatch (which requires the full OTP tree).

  # Helper: write a minimal fiber .md file with a shuttle: block into
  # <host>/.felt/<id>/<basename>.md so read_fiber_shuttle_block can find it.
  defp write_fiber_file(host, fiber_id, shuttle_yaml \\ "enabled: true\nkind: oneshot\n") do
    felt_dir = Path.join(host, ".felt")
    segments = String.split(fiber_id, "/")
    basename = List.last(segments)
    dir_path = Path.join([felt_dir | segments] ++ ["#{basename}.md"])
    File.mkdir_p!(Path.dirname(dir_path))

    indented =
      shuttle_yaml
      |> String.trim()
      |> String.split("\n")
      |> Enum.map_join("\n", &("  " <> &1))

    File.write!(dir_path, "---\nstatus: active\nshuttle:\n#{indented}\n---\nbody\n")
    dir_path
  end

  test "resolve_fiber_host finds a fiber in the first configured host" do
    host_a =
      Path.join(System.tmp_dir!(), "shuttle-multi-host-a-#{System.unique_integer([:positive])}")

    host_b =
      Path.join(System.tmp_dir!(), "shuttle-multi-host-b-#{System.unique_integer([:positive])}")

    File.mkdir_p!(host_a)
    File.mkdir_p!(host_b)

    write_fiber_file(host_a, "tests/fiber-in-a")

    {:ok, poller} =
      Poller.start_link(
        name: :test_multi_host_resolve_a,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: [host_a, host_b]
      )

    assert {:ok, ^host_a} = Poller.resolve_fiber_host(poller, "tests/fiber-in-a")
  after
    Enum.each(
      Path.wildcard(Path.join(System.tmp_dir!(), "shuttle-multi-host-*")),
      &File.rm_rf/1
    )
  end

  test "resolve_fiber_host finds a fiber in the second configured host" do
    host_a =
      Path.join(System.tmp_dir!(), "shuttle-multi-host-a-#{System.unique_integer([:positive])}")

    host_b =
      Path.join(System.tmp_dir!(), "shuttle-multi-host-b-#{System.unique_integer([:positive])}")

    File.mkdir_p!(host_a)
    File.mkdir_p!(host_b)

    write_fiber_file(host_b, "tests/fiber-in-b")

    {:ok, poller} =
      Poller.start_link(
        name: :test_multi_host_resolve_b,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: [host_a, host_b]
      )

    assert {:ok, ^host_b} = Poller.resolve_fiber_host(poller, "tests/fiber-in-b")
  after
    Enum.each(
      Path.wildcard(Path.join(System.tmp_dir!(), "shuttle-multi-host-*")),
      &File.rm_rf/1
    )
  end

  test "resolve_fiber_host returns :not_found for an unknown fiber" do
    host_a =
      Path.join(System.tmp_dir!(), "shuttle-multi-host-a-#{System.unique_integer([:positive])}")

    File.mkdir_p!(host_a)

    {:ok, poller} =
      Poller.start_link(
        name: :test_multi_host_not_found,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: [host_a]
      )

    assert {:error, :not_found} = Poller.resolve_fiber_host(poller, "tests/no-such-fiber")
  after
    Enum.each(
      Path.wildcard(Path.join(System.tmp_dir!(), "shuttle-multi-host-*")),
      &File.rm_rf/1
    )
  end

  test "first-configured host wins for ID collisions" do
    host_a =
      Path.join(System.tmp_dir!(), "shuttle-multi-host-a-#{System.unique_integer([:positive])}")

    host_b =
      Path.join(System.tmp_dir!(), "shuttle-multi-host-b-#{System.unique_integer([:positive])}")

    File.mkdir_p!(host_a)
    File.mkdir_p!(host_b)

    # Same fiber ID in both hosts
    write_fiber_file(host_a, "tests/collision-fiber")
    write_fiber_file(host_b, "tests/collision-fiber")

    {:ok, poller} =
      Poller.start_link(
        name: :test_multi_host_collision,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: [host_a, host_b]
      )

    # host_a is first-configured → wins
    assert {:ok, ^host_a} = Poller.resolve_fiber_host(poller, "tests/collision-fiber")
  after
    Enum.each(
      Path.wildcard(Path.join(System.tmp_dir!(), "shuttle-multi-host-*")),
      &File.rm_rf/1
    )
  end

  test "bust_fiber_host_cache allows re-resolution after a fiber moves" do
    host_a =
      Path.join(System.tmp_dir!(), "shuttle-multi-host-a-#{System.unique_integer([:positive])}")

    host_b =
      Path.join(System.tmp_dir!(), "shuttle-multi-host-b-#{System.unique_integer([:positive])}")

    File.mkdir_p!(host_a)
    File.mkdir_p!(host_b)

    path_a = write_fiber_file(host_a, "tests/movable-fiber")

    {:ok, poller} =
      Poller.start_link(
        name: :test_multi_host_bust,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: [host_a, host_b]
      )

    # Initially resolves to host_a
    assert {:ok, ^host_a} = Poller.resolve_fiber_host(poller, "tests/movable-fiber")

    # "Move" the fiber to host_b (delete from a, write to b)
    File.rm_rf!(Path.dirname(path_a))
    write_fiber_file(host_b, "tests/movable-fiber")

    # Cache still returns host_a without busting
    assert {:ok, ^host_a} = Poller.resolve_fiber_host(poller, "tests/movable-fiber")

    # After bust, re-probes the file system → host_b
    :ok = Poller.bust_fiber_host_cache(poller, "tests/movable-fiber")
    assert {:ok, ^host_b} = Poller.resolve_fiber_host(poller, "tests/movable-fiber")
  after
    Enum.each(
      Path.wildcard(Path.join(System.tmp_dir!(), "shuttle-multi-host-*")),
      &File.rm_rf/1
    )
  end

  test "subdirectory symlink: loom-walks-into-project subtree skipped" do
    # Mirrors loom→lightcone topology: physical .felt lives in host_b
    # (project-canonical, like lightcone). host_a (loom) symlinks INTO
    # host_b's tree at .felt/ai-futures/lightcone. Walking host_a should
    # NOT enumerate the symlinked subtree — host_b enumerates canonically.
    # This is load-bearing: if loom enumerates the lightcone fiber under
    # its loom-relative id, dispatch later runs `felt -C ~/loom show
    # ai-futures/lightcone/...` which fails (loom's index doesn't have
    # the entry) and dispatch silently never happens.
    host_a =
      Path.join(
        System.tmp_dir!(),
        "shuttle-multi-host-loom-#{System.unique_integer([:positive])}"
      )

    host_b =
      Path.join(
        System.tmp_dir!(),
        "shuttle-multi-host-lightcone-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(host_a, ".felt/ai-futures"))
    File.mkdir_p!(host_b)

    # The real fiber file is rooted in host_b's .felt/, accessible via the
    # project-canonical id `lightcone-ui/myst-as-ast/dual-branch`.
    write_fiber_file(host_b, "lightcone-ui/myst-as-ast/dual-branch")

    # host_a (loom) symlinks INTO host_b's tree, so the same physical file
    # is reachable as host_a/.felt/ai-futures/lightcone/lightcone-ui/.../dual-branch.md.
    File.ln_s!(
      Path.join(host_b, ".felt"),
      Path.join([host_a, ".felt", "ai-futures", "lightcone"])
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_subdir_symlink_skip,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: [host_a, host_b]
      )

    # The fiber should resolve to host_b (canonical), not host_a (symlink view).
    assert {:ok, ^host_b} =
             Poller.resolve_fiber_host(poller, "lightcone-ui/myst-as-ast/dual-branch")

    snap = Poller.snapshot(poller)
    candidate_ids = Enum.map(snap.eligible, & &1.fiber_id)

    refute "ai-futures/lightcone/lightcone-ui/myst-as-ast/dual-branch" in candidate_ids,
           "loom-relative symlink-aliased id leaked into eligible: #{inspect(candidate_ids)}"
  after
    Enum.each(
      Path.wildcard(Path.join(System.tmp_dir!(), "shuttle-multi-host-*")),
      &File.rm_rf/1
    )
  end

  test "host with symlinked .felt/ skipped entirely" do
    # Mirrors project-cities-on-loom topology: project's `.felt/` is a
    # symlink into loom's tree. Walking the project host should skip
    # everything — loom enumerates the same files canonically.
    loom =
      Path.join(
        System.tmp_dir!(),
        "shuttle-multi-host-loom-#{System.unique_integer([:positive])}"
      )

    project =
      Path.join(
        System.tmp_dir!(),
        "shuttle-multi-host-project-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(loom)
    File.mkdir_p!(project)

    # Physical fiber rooted in loom under ai-futures/portolan/.
    write_fiber_file(loom, "ai-futures/portolan/kanban-modal")

    # Project's .felt/ symlinks into loom's ai-futures/portolan/ subdir,
    # so the same kanban-modal.md is reachable as project/.felt/kanban-modal/.
    File.ln_s!(
      Path.join([loom, ".felt", "ai-futures", "portolan"]),
      Path.join(project, ".felt")
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_symlinked_felt_skipped,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: [loom, project]
      )

    # The fiber resolves to loom (canonical), not project (symlinked .felt).
    assert {:ok, ^loom} = Poller.resolve_fiber_host(poller, "ai-futures/portolan/kanban-modal")

    snap = Poller.snapshot(poller)
    candidate_ids = Enum.map(snap.eligible, & &1.fiber_id)

    refute "kanban-modal" in candidate_ids,
           "project-symlink alias surfaced: #{inspect(candidate_ids)}"
  after
    Enum.each(
      Path.wildcard(Path.join(System.tmp_dir!(), "shuttle-multi-host-*")),
      &File.rm_rf/1
    )
  end

  test "resolve_fiber_host fallback ignores symlinked project view after cache bust" do
    loom =
      Path.join(
        System.tmp_dir!(),
        "shuttle-multi-host-loom-#{System.unique_integer([:positive])}"
      )

    project =
      Path.join(
        System.tmp_dir!(),
        "shuttle-multi-host-project-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(loom)
    File.mkdir_p!(project)

    write_fiber_file(loom, "ai-futures/portolan/kanban-modal")

    File.ln_s!(
      Path.join([loom, ".felt", "ai-futures", "portolan"]),
      Path.join(project, ".felt")
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_symlinked_felt_cache_bust,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: [loom, project]
      )

    :ok = Poller.bust_fiber_host_cache(poller, "ai-futures/portolan/kanban-modal")

    assert {:ok, ^loom} = Poller.resolve_fiber_host(poller, "ai-futures/portolan/kanban-modal")
  after
    Enum.each(
      Path.wildcard(Path.join(System.tmp_dir!(), "shuttle-multi-host-*")),
      &File.rm_rf/1
    )
  end

  test "snapshot includes felt_stores list" do
    {:ok, poller} =
      Poller.start_link(
        name: :test_multi_host_snap,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp/host-one", "/tmp/host-two"]
      )

    snap = Poller.snapshot(poller)
    assert snap.felt_stores == ["/tmp/host-one", "/tmp/host-two"]
  end

  test "poller reads configured hosts from persisted registration" do
    config_path =
      Path.join(
        System.tmp_dir!(),
        "shuttle-felt-stores-poller-#{System.unique_integer([:positive])}.json"
      )

    original_file = System.get_env("SHUTTLE_FELT_STORES_FILE")
    original_homes = System.get_env("LOOM_HOMES")

    System.put_env("SHUTTLE_FELT_STORES_FILE", config_path)
    System.delete_env("LOOM_HOMES")
    File.mkdir_p!(Path.dirname(config_path))

    File.write!(
      config_path,
      Jason.encode!(%{"version" => 1, "felt_stores" => ["/tmp/host-a", "/tmp/host-b"]})
    )

    on_exit(fn ->
      File.rm(config_path)

      case original_file do
        nil -> System.delete_env("SHUTTLE_FELT_STORES_FILE")
        value -> System.put_env("SHUTTLE_FELT_STORES_FILE", value)
      end

      case original_homes do
        nil -> System.delete_env("LOOM_HOMES")
        value -> System.put_env("LOOM_HOMES", value)
      end
    end)

    {:ok, poller} =
      Poller.start_link(
        name: :test_registered_felt_stores,
        runner: MockRunner,
        poll_interval_ms: 60_000
      )

    assert Poller.snapshot(poller).felt_stores == ["/tmp/host-a", "/tmp/host-b"]
  end

  test "poller refreshes configured hosts when the persisted registration changes" do
    config_path =
      Path.join(
        System.tmp_dir!(),
        "shuttle-felt-stores-refresh-#{System.unique_integer([:positive])}.json"
      )

    original_file = System.get_env("SHUTTLE_FELT_STORES_FILE")
    original_homes = System.get_env("LOOM_HOMES")

    System.put_env("SHUTTLE_FELT_STORES_FILE", config_path)
    System.delete_env("LOOM_HOMES")
    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, Jason.encode!(%{"version" => 1, "felt_stores" => ["/tmp/host-a"]}))

    on_exit(fn ->
      File.rm(config_path)

      case original_file do
        nil -> System.delete_env("SHUTTLE_FELT_STORES_FILE")
        value -> System.put_env("SHUTTLE_FELT_STORES_FILE", value)
      end

      case original_homes do
        nil -> System.delete_env("LOOM_HOMES")
        value -> System.put_env("LOOM_HOMES", value)
      end
    end)

    {:ok, poller} =
      Poller.start_link(
        name: :test_refresh_registered_felt_stores,
        runner: MockRunner,
        poll_interval_ms: 60_000
      )

    assert Poller.snapshot(poller).felt_stores == ["/tmp/host-a"]

    File.write!(config_path, Jason.encode!(%{"version" => 1, "felt_stores" => ["/tmp/host-c"]}))
    send(poller, :run_poll_cycle)
    Process.sleep(50)

    assert Poller.snapshot(poller).felt_stores == ["/tmp/host-c"]
  end

  # ── Claim (write-and-claim) ──

  test "claim registers a live external session: rename, runtime, exit handling" do
    id = "tests/claim-me"
    MockRunner.set_fiber(id, make_fiber(id, %{"uid" => "01CLAIMUID"}))
    MockRunner.set_shuttle(id, @oneshot_shuttle)
    MockRunner.add_tmux_session("capture-abc123")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_claim,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert {:ok, %{session: session}} =
             Poller.claim_session(poller, id, "capture-abc123", session_uuid: "uuid-claim-1")

    # Renamed to the canonical worker name — indistinguishable from a dispatch.
    assert session == "claim-me-01CLAIMUID-shuttle"

    assert Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "rename-session"
           end)

    snap = Poller.snapshot(poller)
    assert Enum.any?(snap.eligible, &(&1.fiber_id == id))

    # The dispatch-shaped history event landed with the session uuid token.
    {out, 0} =
      System.cmd("felt", ["-C", "/tmp", "history", id, "--last", "1", "--json"],
        stderr_to_stdout: true
      )

    assert out =~ "worker claimed"
    assert out =~ "session=uuid-claim-1"

    new_sessions_before =
      Enum.count(MockRunner.commands(), fn {cmd, args} ->
        cmd == "tmux" and hd(args) == "new-session" and Enum.at(args, 3) == session
      end)

    # Exit handling works exactly as for a dispatched active oneshot: the dead
    # session is noticed by reconciliation, the stale running entry clears, and
    # the same poll tick retries the active fiber under its canonical name.
    MockRunner.remove_tmux_session(session)
    send(poller, :run_poll_cycle)

    assert wait_until(
             fn ->
               Enum.count(MockRunner.commands(), fn {cmd, args} ->
                 cmd == "tmux" and hd(args) == "new-session" and Enum.at(args, 3) == session
               end) > new_sessions_before and
                 Enum.any?(Poller.snapshot(poller).eligible, &(&1.fiber_id == id))
             end,
             80
           )
  end

  test "claim refuses unknown fibers, dead sessions, and double claims" do
    id = "tests/claim-guards"
    MockRunner.set_fiber(id, make_fiber(id, %{"uid" => "01GUARDUID"}))
    MockRunner.set_shuttle(id, @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_claim_guards,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Session not live in tmux.
    assert {:error, :session_not_found} =
             Poller.claim_session(poller, id, "capture-dead", [])

    # Fiber unknown.
    MockRunner.add_tmux_session("capture-live01")

    assert {:error, :not_found} =
             Poller.claim_session(poller, "tests/no-such-fiber", "capture-live01", [])

    # First claim wins; a different session claiming the same fiber is refused.
    assert {:ok, %{session: canonical}} = Poller.claim_session(poller, id, "capture-live01", [])
    MockRunner.add_tmux_session("capture-live02")
    assert {:error, :already_running} = Poller.claim_session(poller, id, "capture-live02", [])

    # Idempotent retry: re-claiming with the original (now-renamed-away) name
    # or with the canonical name returns the registered session, not an error —
    # a lost claim response must be retryable with the same body.
    assert {:ok, %{session: ^canonical}} = Poller.claim_session(poller, id, "capture-live01", [])
    assert {:ok, %{session: ^canonical}} = Poller.claim_session(poller, id, canonical, [])
  end

  test "claim refuses closed fibers" do
    id = "tests/claim-closed"
    MockRunner.set_fiber(id, make_fiber(id, %{"status" => "closed"}))
    MockRunner.set_shuttle(id, @oneshot_shuttle, "closed")
    MockRunner.add_tmux_session("capture-closed1")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_claim_closed,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert {:error, :closed} = Poller.claim_session(poller, id, "capture-closed1", [])
  end

  # ── Capture (spawn-without-constitution) ──

  test "capture spawns a tmux session from a free-text prompt" do
    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_capture,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert {:ok, %{session: "capture-" <> _ = session, agent_id: "claude-sonnet"}} =
             Poller.capture(poller, "build me a thing", work_dir: "/tmp")

    # Right tmux command: detached session under the capture name, rooted in
    # the requested project dir — the last free boundary before a real agent.
    assert Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session" and
               Enum.at(args, 3) == session and Enum.at(args, 5) == "/tmp"
           end)

    # Pre-claim, the capture session is invisible to the shuttle-session
    # machinery (not `-shuttle`-suffixed): a poll does not adopt or kill it.
    send(poller, :run_poll_cycle)
    Process.sleep(50)

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "kill-session" and Enum.at(args, 2) =~ "capture-"
           end)
  end
end
