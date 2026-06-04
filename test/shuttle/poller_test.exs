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

    def set_fiber(id, fiber), do: Agent.update(__MODULE__, &put_in(&1.fibers[id], fiber))

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

        state
        |> put_in([:shuttle, id], yaml)
        |> put_in([:fibers, id], fiber)
      end)
    end

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

  defp runtime_store_path do
    Path.join(
      System.tmp_dir!(),
      "shuttle-poller-runtime-test-#{System.unique_integer([:positive])}/runtime.db"
    )
  end

  defp cleanup_runtime_store_paths do
    System.tmp_dir!()
    |> Path.join("shuttle-poller-runtime-test-*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)
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

  # The Poller defaults `own_host_id` from a two-step precedence chain:
  # SHUTTLE_HOST env var → :inet.gethostname(). Explicit `own_host_id:`
  # opts always win; these tests cover the resolution chain that drives
  # production daemons. There is intentionally no Application-config step
  # and no "local" fallback — see Shuttle.Poller.own_host_id/0.
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

  test "poller falls back to :inet.gethostname when SHUTTLE_HOST is unset" do
    prev = System.get_env("SHUTTLE_HOST")
    System.delete_env("SHUTTLE_HOST")
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
      if prev, do: System.put_env("SHUTTLE_HOST", prev)
    end
  end

  test "poller uses projected felt listing for shuttle discovery" do
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

    assert wait_until(fn ->
             Enum.any?(MockRunner.commands(), fn {cmd, args} ->
               cmd == "felt" and
                 args == [
                   "ls",
                   "--json",
                   "--has-field",
                   "shuttle",
                   "--json-field",
                   "id,status,created_at,shuttle,depends_on,tempered"
                 ]
             end)
           end)
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

  test "poller does not dispatch a scheduled standing role before it is due" do
    fiber = make_fiber("tests/standing-sleeping", %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber("tests/standing-sleeping", fiber)

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

  test "poller persists standing-role lifecycle state to the runtime store" do
    fiber_id = "tests/standing-lifecycle-persist"
    runtime_store_path = runtime_store_path()
    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      enabled: true
      kind: standing
      schedule:
        expr: "0 9 * * 1-5"
        tz: Europe/Paris
      review:
        state: awaiting
        run_id: run-1
        accepted_run_id: null
      next_due_at: null
      last_run_at: "2026-06-02T09:13:00+02:00"
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_lifecycle_persist,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"],
        runtime_store_path: runtime_store_path
      )

    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             Shuttle.RuntimeStore.list_lifecycle(runtime_store_path)
             |> Enum.any?(&(&1.fiber_id == fiber_id))
           end)

    assert [
             %{
               fiber_id: ^fiber_id,
               metadata: %{
                 kind: "standing",
                 phase: "awaiting",
                 run_id: "run-1",
                 review: %{"state" => "awaiting"}
               }
             }
           ] = Shuttle.RuntimeStore.list_lifecycle(runtime_store_path)

    assert [%{fiber_id: ^fiber_id, state: "review", run_id: "run-1"}] =
             Poller.snapshot(poller).standing_roles
  after
    cleanup_runtime_store_paths()
  end

  test "poller overlays persisted lifecycle when rebuilding standing-role snapshots" do
    fiber_id = "tests/standing-lifecycle-overlay"
    runtime_store_path = runtime_store_path()
    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      enabled: true
      kind: standing
      schedule:
        expr: "0 9 * * 1-5"
        tz: Europe/Paris
      review:
        state: scheduled
      next_due_at: null
      """
    )

    Shuttle.RuntimeStore.upsert_lifecycle(runtime_store_path, fiber_id, %{
      kind: "standing",
      phase: "scheduled",
      run_id: nil,
      next_due_at: ~U[2999-01-01 08:00:00Z],
      last_run_at: nil,
      review: %{"state" => "scheduled"}
    })

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_lifecycle_overlay,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"],
        runtime_store_path: runtime_store_path
      )

    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             match?([%{fiber_id: ^fiber_id}], Poller.snapshot(poller).standing_roles)
           end)

    assert [%{fiber_id: ^fiber_id, state: "scheduled", validation_errors: []}] =
             Poller.snapshot(poller).standing_roles
  after
    cleanup_runtime_store_paths()
  end

  # Regression: standing-role review state lives in the runtime store, not the
  # frontmatter (LifecycleStore evicts it). Action resolution must overlay it,
  # or `accept-run` on an awaiting role is wrongly rejected as
  # `action_not_available` (the kanban "can't temper the weekly arXiv role" bug).
  test "actions reflect runtime-store review state even when the frontmatter omits it" do
    fiber_id = "tests/standing-actions-overlay"
    runtime_store_path = runtime_store_path()
    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber(fiber_id, fiber)

    # No review: block in the frontmatter — the daemon owns review state.
    MockRunner.set_shuttle(
      fiber_id,
      """
      enabled: true
      kind: standing
      schedule:
        expr: "0 9 * * 1"
        tz: Europe/Paris
      """
    )

    Shuttle.RuntimeStore.upsert_lifecycle(runtime_store_path, fiber_id, %{
      kind: "standing",
      phase: "awaiting",
      run_id: "run-1",
      next_due_at: nil,
      last_run_at: nil,
      review: %{"state" => "awaiting", "run_id" => "run-1"}
    })

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_actions_overlay,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"],
        runtime_store_path: runtime_store_path
      )

    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             match?([%{fiber_id: ^fiber_id}], Poller.snapshot(poller).standing_roles)
           end)

    {:ok, actions} = Poller.actions_for(poller, fiber_id, [])
    ids = Enum.map(actions, &(Map.get(&1, :id) || Map.get(&1, "id")))
    assert "accept-run" in ids

    assert {:ok, %{id: "accept-run"}} =
             Poller.resolve_action(poller, fiber_id, "tempered", [])
  after
    cleanup_runtime_store_paths()
  end

  # Regression: accepting a standing run through the Poller must advance the
  # runtime store AND refresh the in-memory lifecycle cache, or the very next
  # poll re-derives the role from the stale cache and clobbers the acceptance
  # straight back to `awaiting` (why an accepted weekly-arXiv run kept
  # reappearing in Awaiting review).
  test "accept through the Poller advances the runtime store and survives the next poll" do
    fiber_id = "tests/standing-accept-sticks"
    runtime_store_path = runtime_store_path()
    File.mkdir_p!(Path.dirname(runtime_store_path))

    previous_runtime_store = System.get_env("SHUTTLE_RUNTIME_STORE")
    previous_loom_homes = System.get_env("LOOM_HOMES")
    # LifecycleStore reads SHUTTLE_RUNTIME_STORE; share it with the Poller so
    # both sides of the transition touch the same DB (mirrors production, where
    # both fall back to the same default path).
    System.put_env("SHUTTLE_RUNTIME_STORE", runtime_store_path)
    System.put_env("LOOM_HOMES", "/tmp")

    on_exit(fn ->
      restore_env("SHUTTLE_RUNTIME_STORE", previous_runtime_store)
      restore_env("LOOM_HOMES", previous_loom_homes)
    end)

    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      enabled: true
      kind: standing
      schedule:
        expr: "0 9 * * 1"
        tz: Europe/Paris
      """
    )

    Shuttle.RuntimeStore.upsert_lifecycle(runtime_store_path, fiber_id, %{
      kind: "standing",
      phase: "awaiting",
      run_id: "20260601T070000+0000",
      next_due_at: nil,
      last_run_at: nil,
      review: %{"state" => "awaiting", "run_id" => "20260601T070000+0000"}
    })

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_accept_sticks,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert {:ok, _output} = Poller.lifecycle_transition(poller, :accept, fiber_id, [])

    assert %{phase: "scheduled", review: %{"state" => "scheduled"}} =
             Shuttle.RuntimeStore.fetch_lifecycle(runtime_store_path, fiber_id)

    send(poller, :run_poll_cycle)
    Process.sleep(75)

    assert %{phase: "scheduled"} =
             Shuttle.RuntimeStore.fetch_lifecycle(runtime_store_path, fiber_id),
           "the next poll clobbered the acceptance back to awaiting"
  after
    cleanup_runtime_store_paths()
  end

  test "an accept that lands during a poll read is not clobbered when the poll completes" do
    # Regression for Symptom B of the poll-merge wedge (sibling of the retry
    # case): a standing-role `accept` writes `scheduled` to the runtime store,
    # but pre-refactor a poll Task already in flight — snapshotted while the role
    # was still `awaiting` — recomputed lifecycle from that stale snapshot,
    # re-persisted `awaiting`, and `merge_poll_cycle_state` set
    # `lifecycle: poll_state.lifecycle`, reverting the acceptance. Post-refactor
    # the Task only reads; lifecycle is recomputed and persisted in
    # `apply_poll_cycle/2` from current state, so the accept stands. The sibling
    # test above does NOT catch this — it accepts before the poll even starts.
    fiber_id = "tests/standing-accept-during-poll"
    runtime_store_path = runtime_store_path()
    File.mkdir_p!(Path.dirname(runtime_store_path))

    previous_runtime_store = System.get_env("SHUTTLE_RUNTIME_STORE")
    previous_loom_homes = System.get_env("LOOM_HOMES")
    System.put_env("SHUTTLE_RUNTIME_STORE", runtime_store_path)
    System.put_env("LOOM_HOMES", "/tmp")

    on_exit(fn ->
      restore_env("SHUTTLE_RUNTIME_STORE", previous_runtime_store)
      restore_env("LOOM_HOMES", previous_loom_homes)
    end)

    fiber = make_fiber(fiber_id, %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      enabled: true
      kind: standing
      schedule:
        expr: "0 9 * * 1"
        tz: Europe/Paris
      """
    )

    Shuttle.RuntimeStore.upsert_lifecycle(runtime_store_path, fiber_id, %{
      kind: "standing",
      phase: "awaiting",
      run_id: "20260601T070000+0000",
      next_due_at: nil,
      last_run_at: nil,
      review: %{"state" => "awaiting", "run_id" => "20260601T070000+0000"}
    })

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_accept_during_poll,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Hold the next poll inside its read-only felt walk; its snapshot still sees
    # the role as `awaiting`.
    MockRunner.set_felt_ls_delay(400)
    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             Enum.any?(MockRunner.commands(), fn {cmd, args} ->
               cmd == "felt" and Enum.take(args, 2) == ["ls", "--json"]
             end)
           end)

    # Accept while the poll is still reading (the GenServer stays responsive).
    assert {:ok, _output} = Poller.lifecycle_transition(poller, :accept, fiber_id, [])

    assert %{phase: "scheduled"} =
             Shuttle.RuntimeStore.fetch_lifecycle(runtime_store_path, fiber_id)

    # Let the held poll complete and apply against current state.
    Process.sleep(500)

    assert %{phase: "scheduled"} =
             Shuttle.RuntimeStore.fetch_lifecycle(runtime_store_path, fiber_id),
           "a poll completing after the accept reverted the acceptance to awaiting"
  after
    cleanup_runtime_store_paths()
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

  test "direct ad-hoc dispatch refuses a standing role awaiting review" do
    fiber_id = "tests/standing-awaiting-refuses-adhoc"
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
        state: awaiting
        run_id: "adhoc-1778282769604"
        completed_at: "2026-05-24T10:00:00Z"
      next_due_at: "2999-01-01T09:00:00+01:00"
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_awaiting_refuses_adhoc,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert {:error, {:awaiting_review, "adhoc-1778282769604", "2026-05-24T10:00:00Z"}} =
             Poller.dispatch_fiber(poller, fiber_id, force: true, ad_hoc: true)

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
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

    # Spawn a worker so the fiber is in state.running.
    assert {:ok, session} = Poller.dispatch_fiber(poller, fiber_id, force: true)
    assert session == Dispatcher.session_name(fiber_id)

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
      enabled: true
      kind: standing
      agent: claude-sonnet
      schedule:
        expr: "0 9 * * 1-5"
        tz: Europe/Paris
      review:
        state: awaiting
        run_id: "adhoc-1779793385922"
        completed_at: "2026-05-26T12:40:00Z"
      session:
        id: stored-standing-session-id
      next_due_at: "2999-01-01T09:00:00+01:00"
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_force_resume_before_window,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

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

  test "force-dispatch runs a disabled fiber (shuttle.enabled: false)" do
    # A fiber that opted out of auto-dispatch (enabled: false) is still
    # available for explicit manual launch — the click is the override.
    fiber_id = "tests/disabled-force"
    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, "enabled: false\nkind: oneshot\nagent: claude-sonnet\n")

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

    MockRunner.set_shuttle(
      "tests/standing-due",
      """
      enabled: true
      kind: standing
      agent: claude-sonnet
      schedule:
        expr: "0 9 * * 1-5"
        tz: Europe/Paris
      review:
        state: scheduled
      next_due_at: "2000-01-03T09:00:00+01:00"
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

  test "poller rejects stale accepted standing metadata" do
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
      review:
        state: accepted
        run_id: run-2
        accepted_run_id: run-1
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

    assert [%{fiber_id: "tests/standing-stale", validation_errors: errors}] =
             Poller.snapshot(poller).standing_roles

    assert Enum.any?(errors, &String.contains?(&1, "accepted_run_id"))
  end

  test "snapshot exposes review and accepted standing states" do
    review = make_fiber("tests/standing-review", %{"tags" => ["constitution", "standing"]})
    accepted = make_fiber("tests/standing-accepted", %{"tags" => ["constitution", "standing"]})
    MockRunner.set_fiber("tests/standing-review", review)
    MockRunner.set_fiber("tests/standing-accepted", accepted)

    MockRunner.set_shuttle(
      "tests/standing-review",
      """
      enabled: true
      mode: standing
      schedule:
        kind: cron
        expr: "0 9 * * 1-5"
        timezone: Europe/Paris
      review:
        state: awaiting
        run_id: run-1
        accepted_run_id: null
      next_due_at: null
      last_run_at: "2026-05-02T09:12:00+02:00"
      """
    )

    MockRunner.set_shuttle(
      "tests/standing-accepted",
      """
      enabled: true
      mode: standing
      schedule:
        kind: cron
        expr: "0 9 * * 1-5"
        timezone: Europe/Paris
      review:
        state: accepted
        run_id: run-2
        accepted_run_id: run-2
      next_due_at: "2999-01-01T09:00:00+01:00"
      last_run_at: "2026-05-02T09:12:00+02:00"
      """
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
    assert Enum.find(roles, &(&1.fiber_id == "tests/standing-review")).state == "review"
    assert Enum.find(roles, &(&1.fiber_id == "tests/standing-accepted")).state == "accepted"
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

  test "poller schedules retry when worker exits and fiber still active" do
    # Uses "tests/haiku-retry" to avoid session collisions — this test leaves two
    # WorkerWatcher processes alive (initial + retry) that would interfere with
    # subsequent tests using the same session name "haiku-shuttle".
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

    # Simulate worker exit (tmux session dies)
    MockRunner.remove_tmux_session(Dispatcher.session_name("tests/haiku-retry"))
    send(poller, {:worker_exited, "tests/haiku-retry", :normal_exit, false})
    Process.sleep(50)

    snap2 = Poller.snapshot(poller)
    assert length(snap2.eligible) == 0
    assert length(snap2.retrying) == 1
    assert hd(snap2.retrying).fiber_id == "tests/haiku-retry"

    assert wait_until(
             fn ->
               MockRunner.commands()
               |> Enum.count(fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)
               |> Kernel.==(2)
             end,
             80
           )
  end

  test "a continuation retry scheduled during a poll read survives the cycle with a live timer" do
    # Regression for the wedge that motivated making the poll Task a pure read.
    # Pre-refactor, the Task computed a rival %State{} from a pre-exit snapshot
    # and `merge_poll_cycle_state` reassembled `running`/`retry_queue` from two
    # lineages — so a worker-exit retry scheduled *while a poll was in flight*
    # could be dropped (fiber resurrected into `running`) or have its timer
    # orphaned (entry survives, timer already fired), wedging the fiber until a
    # daemon restart. Post-refactor the Task only reads; the retry is born and
    # lives in the GenServer's current state, which the completing poll never
    # overwrites. This test holds a poll mid-read, schedules the retry, lets the
    # poll complete, and asserts the retry is intact with a LIVE timer.
    fiber_id = "tests/retry-survives-poll"
    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_retry_survives_poll,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert {:ok, session} = Poller.dispatch_fiber(poller, fiber_id, [])

    # Hold the next poll cycle inside its read-only felt walk, then confirm the
    # Task is actually mid-read (its snapshot has the fiber running).
    MockRunner.set_felt_ls_delay(400)
    send(poller, :run_poll_cycle)

    assert wait_until(fn ->
             Enum.any?(MockRunner.commands(), fn {cmd, args} ->
               cmd == "felt" and Enum.take(args, 2) == ["ls", "--json"]
             end)
           end)

    # Worker exits while the poll is still reading. handle_worker_exit schedules
    # a continuation retry on the GenServer's CURRENT state.
    MockRunner.remove_tmux_session(session)
    send(poller, {:worker_exited, fiber_id, :normal_exit, false})

    assert wait_until(fn ->
             snap = Poller.snapshot(poller)
             Enum.any?(snap.retrying, &(&1.fiber_id == fiber_id))
           end)

    # Let the held poll complete (~400ms) and apply against current state.
    Process.sleep(500)

    state = :sys.get_state(poller)
    retry = Map.get(state.retry_queue, fiber_id)

    assert retry, "continuation retry was dropped by the completing poll cycle"
    assert is_reference(retry.timer_ref)

    assert Process.read_timer(retry.timer_ref),
           "retry timer was orphaned (already fired/cancelled) — the fiber would wedge"

    assert MapSet.member?(state.claimed, fiber_id)

    refute Map.has_key?(state.running, fiber_id),
           "the exited fiber must not be resurrected into running by the completing poll"
  end

  test "poller rehydrates pending retries from runtime store on restart" do
    fiber_id = "tests/retry-rehydrate"
    runtime_store_path = runtime_store_path()

    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_retry_rehydrate_1,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"],
        runtime_store_path: runtime_store_path
      )

    assert {:ok, session} = Poller.dispatch_fiber(poller, fiber_id, [])
    MockRunner.remove_tmux_session(session)
    send(poller, {:worker_exited, fiber_id, :normal_exit, false})

    assert wait_until(fn ->
             Poller.snapshot(poller).retrying
             |> Enum.any?(&(&1.fiber_id == fiber_id))
           end)

    assert [
             %{
               fiber_id: ^fiber_id,
               metadata: %{attempt: 1, delay_type: :continuation}
             }
           ] = Shuttle.RuntimeStore.list_retries(runtime_store_path)

    GenServer.stop(poller)

    {:ok, restarted} =
      Poller.start_link(
        name: :test_poller_retry_rehydrate_2,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"],
        runtime_store_path: runtime_store_path
      )

    assert wait_until(
             fn ->
               MockRunner.commands()
               |> Enum.count(fn {cmd, args} -> cmd == "tmux" and hd(args) == "new-session" end)
               |> Kernel.==(2)
             end,
             80
           )

    refute Enum.any?(Poller.snapshot(restarted).retrying, &(&1.fiber_id == fiber_id))
    assert [] = Shuttle.RuntimeStore.list_retries(runtime_store_path)
  after
    cleanup_runtime_store_paths()
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
      enabled: true
      kind: oneshot
      agent: claude-sonnet
      session:
        id: stored-session-id
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_force_resume_unified,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # File the review-comment first (mirrors the kanban modal's order:
    # file directive → dispatch).
    append_review_comment(fiber_id, resume_mode: "previous")

    assert {:ok, _session} = Poller.dispatch_fiber(poller, fiber_id, force: true)

    # The dispatch produced a --resume invocation against the stored
    # session id, not a fresh new-session.
    script_path = new_session_scripts() |> List.last()
    assert script_path, "expected at least one new-session script"
    script = File.read!(script_path)

    assert script =~ "--resume"
    assert script =~ "stored-session-id"
  end

  test "poller continuation retries start fresh even after resume-previous review comment" do
    fiber_id = "tests/continuation-fresh-despite-review-comment"

    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)

    MockRunner.set_shuttle(
      fiber_id,
      """
      enabled: true
      kind: oneshot
      agent: claude-sonnet
      session:
        id: old-session-id
      """
    )

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_continuation_forces_fresh,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    send(poller, :run_poll_cycle)

    # `session.id: old-session-id` in the fiber file makes this an "orphaned
    # dispatch" on first poll — the daemon sees a session was once dispatched
    # but no tmux session is alive for it. Goes through continuation retry
    # (with force_fresh: true) rather than direct dispatch, so the first new
    # session shows up after the @continuation_retry_delay_ms gate (~1s).
    # 80 attempts × 25ms = 2s, comfortably covers the gate.
    assert wait_until(fn -> length(new_session_scripts()) == 1 end, 80)

    append_review_comment(fiber_id, resume_mode: "previous")

    MockRunner.remove_tmux_session(Dispatcher.session_name(fiber_id))
    send(poller, {:worker_exited, fiber_id, :normal_exit, false})

    assert wait_until(fn -> length(new_session_scripts()) == 2 end, 80)

    [first_script | rest] = new_session_scripts()
    second_script = rest |> List.last() |> File.read!()

    # Both the orphan-resurrection retry and the post-worker-exit continuation
    # retry must dispatch fresh — no --resume of the stale UUID baked in.
    first_script_body = first_script |> File.read!()
    assert first_script_body =~ "Fiber: #{fiber_id}"
    refute first_script_body =~ "--resume"
    refute first_script_body =~ "old-session-id"

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

  test "poller resurrects orphaned oneshot when shuttle.session.id is set but tmux session is dead" do
    # Simulates: oneshot was dispatched (so shuttle.session.id is in the fiber
    # file), the worker exited while the daemon was down (so no worker_exited
    # ever fired and no continuation retry was scheduled), and on next poll
    # cycle the daemon must notice and schedule a continuation retry itself.
    # Without this, the fiber sits "in-flight but dead" forever — the upstream
    # cause of the kanban gotcha-classifier-orphaned-oneshot.
    fiber_id = "tests/orphan-dispatched-dead"

    dispatched_shuttle = """
    enabled: true
    kind: oneshot
    session:
      id: 577af64b-644a-4733-9e6a-f60d86b6941f
      dispatched_at: 2026-05-24T10:36:35.176394Z
    """

    MockRunner.set_shuttle(fiber_id, dispatched_shuttle)
    # No add_tmux_session — the dispatched session has died.

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_resurrect_orphan,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    assert wait_until(fn ->
             snap = Poller.snapshot(poller)
             Enum.any?(snap.retrying, &(&1.fiber_id == fiber_id))
           end)

    snap = Poller.snapshot(poller)
    retry = Enum.find(snap.retrying, &(&1.fiber_id == fiber_id))
    assert retry, "expected a retry entry for the orphaned fiber"
    # Continuation retries use a short fixed delay (@continuation_retry_delay_ms,
    # typically ~1s) rather than the exponential failure backoff. The retry
    # being scheduled at all is the contract — exact delay belongs to retry_delay/3.
    assert retry.attempt == 1
  end

  test "poller resurrects orphaned oneshot from runtime session when frontmatter is document-only" do
    fiber_id = "tests/orphan-runtime-session"
    runtime_store_path = runtime_store_path()

    MockRunner.set_shuttle(fiber_id, """
    enabled: true
    kind: oneshot
    """)

    Shuttle.RuntimeStore.upsert_lifecycle(runtime_store_path, fiber_id, %{
      kind: "oneshot",
      phase: "dispatched",
      session: %{
        "id" => "runtime-session-577af64b",
        "agent" => "codex",
        "dispatched_at" => "2026-05-24T10:36:35.176394Z"
      }
    })

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_resurrect_runtime_session,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"],
        runtime_store_path: runtime_store_path
      )

    assert wait_until(fn ->
             snap = Poller.snapshot(poller)
             Enum.any?(snap.retrying, &(&1.fiber_id == fiber_id))
           end)

    snap = Poller.snapshot(poller)
    assert %{attempt: 1} = Enum.find(snap.retrying, &(&1.fiber_id == fiber_id))
  after
    cleanup_runtime_store_paths()
  end

  # Regression for the 2026-05-30 incident: a cineca/candide restart resurrected
  # Mac-owned Portolan constitutions locally because the orphan-resurrection
  # path never read `host`. The cutover routes resurrection through the same
  # strict predicate as the poll path — a fiber owned by another host is not
  # this daemon's orphan to resurrect.
  test "poller does not resurrect a foreign-host orphaned oneshot" do
    fiber_id = "tests/orphan-foreign-host"

    MockRunner.set_shuttle(fiber_id, """
    enabled: true
    kind: oneshot
    host: some-other-machine
    session:
      id: 577af64b-644a-4733-9e6a-f60d86b6941f
      dispatched_at: 2026-05-24T10:36:35.176394Z
    """)

    # No add_tmux_session — the dispatched session has died. own_host_id is the
    # default "test-host", which does not equal "some-other-machine".
    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_resurrect_foreign_host,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Give the reconcile pass time to (not) act.
    Process.sleep(150)

    snap = Poller.snapshot(poller)

    refute Enum.any?(snap.retrying, &(&1.fiber_id == fiber_id)),
           "a foreign-host orphan must never be resurrected on this daemon"

    assert snap.claimed_count == 0

    refute Enum.any?(MockRunner.commands(), fn {cmd, args} ->
             cmd == "tmux" and hd(args) == "new-session"
           end)
  end

  # The project_dir disqualifier applies to resurrection too: a checkout that
  # does not exist on this host means the worker can't run here, owned or not.
  test "poller does not resurrect an orphan whose declared project_dir is missing" do
    fiber_id = "tests/orphan-missing-project-dir"

    MockRunner.set_shuttle(fiber_id, """
    enabled: true
    kind: oneshot
    host: test-host
    project_dir: /nonexistent/path/shuttle-orphan-missing
    session:
      id: 577af64b-644a-4733-9e6a-f60d86b6941f
      dispatched_at: 2026-05-24T10:36:35.176394Z
    """)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_resurrect_missing_project_dir,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    Process.sleep(150)

    snap = Poller.snapshot(poller)

    refute Enum.any?(snap.retrying, &(&1.fiber_id == fiber_id)),
           "an orphan with a missing project_dir must not be resurrected here"

    assert snap.claimed_count == 0
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

  test "poller does not resurrect a standing role even when its session.id is stale" do
    # Standing roles use review.state for lifecycle, not session.id presence;
    # an old session.id is the historical marker for the most recent run, not
    # a "should be running now" signal. Resurrecting them would cause them to
    # bypass their schedule.
    fiber_id = "tests/standing-stale-session"

    standing_shuttle = """
    enabled: true
    kind: standing
    schedule: "0 9 * * *"
    session:
      id: standing-past-run-uuid
    review:
      state: scheduled
    """

    MockRunner.set_shuttle(fiber_id, standing_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_standing_not_resurrected,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    Process.sleep(150)
    snap = Poller.snapshot(poller)

    refute Enum.any?(snap.retrying, &(&1.fiber_id == fiber_id)),
           "standing roles must not be resurrected by the orphan reconcile pass"
  end

  test "poller does not resurrect a closed oneshot even with session.id set" do
    fiber_id = "tests/closed-with-session"

    dispatched_shuttle = """
    enabled: true
    kind: oneshot
    session:
      id: closed-uuid
    """

    MockRunner.set_shuttle(fiber_id, dispatched_shuttle, "closed")

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_closed_not_resurrected,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    Process.sleep(150)
    snap = Poller.snapshot(poller)
    refute Enum.any?(snap.retrying, &(&1.fiber_id == fiber_id))
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

  test "poller rehydrates live running workers from the runtime store on restart" do
    fiber_id = "tests/runtime-rehydrate-live"
    runtime_store_path = runtime_store_path()

    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_runtime_rehydrate_live_1,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"],
        runtime_store_path: runtime_store_path
      )

    assert {:ok, session} = Poller.dispatch_fiber(poller, fiber_id, [])
    assert Enum.any?(Poller.snapshot(poller).eligible, &(&1.fiber_id == fiber_id))

    GenServer.stop(poller)

    {:ok, restarted} =
      Poller.start_link(
        name: :test_poller_runtime_rehydrate_live_2,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"],
        runtime_store_path: runtime_store_path
      )

    assert wait_until(fn ->
             Poller.snapshot(restarted).eligible
             |> Enum.any?(&(&1.fiber_id == fiber_id and &1.tmux_session == session))
           end)
  after
    cleanup_runtime_store_paths()
  end

  test "poller drops runtime store records whose tmux session disappeared while daemon was down" do
    fiber_id = "tests/runtime-rehydrate-missing"
    runtime_store_path = runtime_store_path()

    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        name: :test_poller_runtime_rehydrate_missing_1,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"],
        runtime_store_path: runtime_store_path
      )

    assert {:ok, session} = Poller.dispatch_fiber(poller, fiber_id, [])

    GenServer.stop(poller)
    MockRunner.remove_tmux_session(session)

    {:ok, restarted} =
      Poller.start_link(
        name: :test_poller_runtime_rehydrate_missing_2,
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"],
        runtime_store_path: runtime_store_path
      )

    snap = Poller.snapshot(restarted)

    assert [
             %{
               fiber_id: ^fiber_id,
               tmux_session: ^session,
               reason: "missing_tmux_session"
             }
             | _
           ] = snap.orphans

    assert [] = Shuttle.RuntimeStore.list_running(runtime_store_path)
  after
    cleanup_runtime_store_paths()
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
end
