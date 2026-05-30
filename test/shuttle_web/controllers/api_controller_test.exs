defmodule ShuttleWeb.APIControllerTest do
  @moduledoc """
  Tests for the Stage 5 Agent-API REST endpoints.
  """

  use ExUnit.Case
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.ChannelTest, except: [connect: 3]

  @endpoint ShuttleWeb.Endpoint

  alias Shuttle.Poller
  alias Shuttle.Dispatcher
  alias ShuttleWeb.UserSocket

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
          new_session_delay_ms: 0
        }
      end)
    end

    def set_fiber(id, fiber), do: Agent.update(__MODULE__, &put_in(&1.fibers[id], fiber))

    # Write a real .md file carrying the given shuttle: block and felt status so
    # that walk_shuttle_fibers (the file-walk discovery path) can find it.
    def set_shuttle(id, yaml, status \\ "active") do
      # Post-cutover every installed block carries an explicit host: equal to
      # the owning daemon's own_host_id (strict eligibility, no nil-wildcard).
      # Stamp the test daemon's identity ("test-host", from SHUTTLE_HOST in
      # config/test.exs) when the YAML omits host:, so generic dispatch tests
      # stay eligible. Host-specific tests pass an explicit host: line.
      yaml =
        if Regex.match?(~r/^\s*host\s*:/m, yaml),
          do: yaml,
          else: String.trim_trailing(yaml) <> "\nhost: test-host\n"

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

    # Kept for backward compat; discovery now walks files for shuttle: blocks.
    def set_felt_ls(fibers), do: Agent.update(__MODULE__, &%{&1 | felt_ls: fibers})

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

    start_supervised!(
      {Poller, runner: MockRunner, poll_interval_ms: 600_000, felt_stores: ["/tmp"]}
    )

    Process.sleep(50)
    :ok
  end

  # Minimal shuttle: block YAML for a oneshot fiber ready for dispatch.
  @oneshot_shuttle "enabled: true\nkind: oneshot\n"

  defp api_conn do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

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

  defp with_actions_host do
    previous = System.get_env("LOOM_HOMES")
    System.put_env("LOOM_HOMES", "/tmp")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("LOOM_HOMES")
        value -> System.put_env("LOOM_HOMES", value)
      end
    end)
  end

  # ── GET /api/v1/workers/:fiber_id ──

  test "returns running worker info" do
    fiber = make_fiber("tests/haiku")
    MockRunner.set_fiber("tests/haiku", fiber)
    MockRunner.set_shuttle("tests/haiku", @oneshot_shuttle)

    send(Shuttle.Poller, :run_poll_cycle)
    Process.sleep(100)

    conn = get(api_conn(), "/api/v1/workers/tests/haiku")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["running"] == true
    assert body["fiber_id"] == "tests/haiku"
    assert body["agent"] == "claude-sonnet"
    assert body["runtime_seconds"] >= 0
  end

  test "returns not running for idle fiber" do
    conn = get(api_conn(), "/api/v1/workers/tests/idle")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["running"] == false
    assert body["fiber_id"] == "tests/idle"
  end

  # ── POST /api/v1/dispatch ──

  test "dispatches a fiber via API" do
    fiber = make_fiber("tests/api-dispatch")
    MockRunner.set_fiber("tests/api-dispatch", fiber)
    MockRunner.set_shuttle("tests/api-dispatch", @oneshot_shuttle)

    conn =
      post(
        api_conn(),
        "/api/v1/dispatch",
        Jason.encode!(%{
          "fiber_id" => "tests/api-dispatch",
          "notify_on_exit" => true
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["dispatched"] == true
    assert body["fiber_id"] == "tests/api-dispatch"
    assert body["tmux_session"] == Dispatcher.session_name("tests/api-dispatch")
    assert body["notify_on_exit"] == true
    assert body["channel_topic"] == "shuttle:worker:tests/api-dispatch"
  end

  test "dispatch returns 409 for already running fiber" do
    fiber = make_fiber("tests/api-dispatch-2")
    MockRunner.set_fiber("tests/api-dispatch-2", fiber)
    MockRunner.add_tmux_session(Dispatcher.session_name("tests/api-dispatch-2"))

    conn =
      post(
        api_conn(),
        "/api/v1/dispatch",
        Jason.encode!(%{
          "fiber_id" => "tests/api-dispatch-2"
        })
      )

    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)
    assert body["dispatched"] == false
    assert body["reason"] == "already_running"
  end

  test "dispatch clears stale in-memory running state when tmux session is gone" do
    fiber_id = "tests/api-stale-running"
    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)

    assert {:ok, session} = Poller.dispatch_fiber(fiber_id, [])
    MockRunner.remove_tmux_session(session)

    conn =
      post(
        api_conn(),
        "/api/v1/dispatch",
        Jason.encode!(%{
          "fiber_id" => fiber_id
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["dispatched"] == true
    assert body["fiber_id"] == fiber_id
    assert body["tmux_session"] == session
  end

  test "dispatch returns 200 for slow successful dispatches past the default call timeout" do
    fiber_id = "tests/api-slow-dispatch"
    fiber = make_fiber(fiber_id)
    MockRunner.set_fiber(fiber_id, fiber)
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)
    MockRunner.set_new_session_delay(5_250)

    started_at_ms = System.monotonic_time(:millisecond)

    conn =
      post(
        api_conn(),
        "/api/v1/dispatch",
        Jason.encode!(%{
          "fiber_id" => fiber_id
        })
      )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

    assert elapsed_ms >= 5_000
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["dispatched"] == true
    assert body["fiber_id"] == fiber_id
    assert body["tmux_session"] == Dispatcher.session_name(fiber_id)
  end

  test "dispatch returns 400 without fiber_id" do
    conn = post(api_conn(), "/api/v1/dispatch", Jason.encode!(%{}))
    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "fiber_id is required"
  end

  test "ad-hoc dispatch returns 422 for a standing role awaiting review" do
    fiber_id = "tests/api-awaiting-refuses-adhoc"
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

    conn =
      post(
        api_conn(),
        "/api/v1/dispatch",
        Jason.encode!(%{
          "fiber_id" => fiber_id,
          "ad_hoc" => true
        })
      )

    assert conn.status == 422
    body = Jason.decode!(conn.resp_body)
    assert body["dispatched"] == false
    assert body["reason"] == "awaiting_review"
    assert body["run_id"] == "adhoc-1778282769604"
    assert body["message"] =~ "shuttle-ctl accept #{fiber_id}"
    assert body["message"] =~ "shuttle-ctl resume #{fiber_id}"
  end

  # ── Shuttle actions ──

  @tag :capture_log
  test "actions resolve returns the canonical lifecycle action from local frontmatter" do
    with_actions_host()

    MockRunner.set_shuttle(
      "tests/action-awaiting",
      "enabled: true\nkind: standing\nreview:\n  state: awaiting\n",
      "active"
    )

    conn =
      post(
        api_conn(),
        "/api/v1/actions/resolve",
        Jason.encode!(%{fiber_id: "tests/action-awaiting", target: "tempered"})
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["fiber_id"] == "tests/action-awaiting"
    assert body["target"] == "tempered"
    assert body["action"]["id"] == "accept-run"

    refute Enum.any?(MockRunner.commands(), fn {command, args} ->
             command == "felt" and "show" in args
           end)
  end

  # Inline-fiber mode: the caller (Portolan) already has the fiber map in
  # memory — e.g. for a remote-origin transition where the fiber lives on a
  # different host than the daemon can see. Skip the disk lookup and resolve
  # purely from the supplied map.
  @tag :capture_log
  test "actions resolve accepts an inline fiber map and skips disk lookup" do
    inline_fiber = %{
      "id" => "remote/host/standing-awaiting",
      "status" => "active",
      "shuttle" => %{
        "enabled" => true,
        "kind" => "standing",
        "review" => %{"state" => "awaiting"}
      }
    }

    conn =
      post(
        api_conn(),
        "/api/v1/actions/resolve",
        Jason.encode!(%{fiber: inline_fiber, target: "inFlight"})
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["fiber_id"] == "remote/host/standing-awaiting"
    assert body["target"] == "inFlight"
    assert body["action"]["id"] == "accept-run"
    assert body["action"]["invocation"]["verb"] == "accept"

    # The inline path must not touch disk: no felt-store lookups, no MockRunner
    # commands ran in the resolve path.
    refute Enum.any?(MockRunner.commands(), fn {command, _args} ->
             command in ["felt", "shuttle-ctl"]
           end)
  end

  @tag :capture_log
  test "actions invoke rejects unavailable action ids before mutating" do
    with_actions_host()
    MockRunner.set_shuttle("tests/action-oneshot", @oneshot_shuttle)

    conn =
      post(
        api_conn(),
        "/api/v1/actions/invoke",
        Jason.encode!(%{fiber_id: "tests/action-oneshot", action: "accept-run"})
      )

    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "action_not_available"
    assert body["invoked"] == false
  end

  # Regression: the daemon used to shell out to `shuttle-ctl` without
  # `--felt-store`, so the CLI's default discovery (PWD walk / loom default)
  # could land on a different store than the one fetch_fiber/1 resolved the
  # fiber against. Symptom: "shuttle: fiber X has no shuttle: block" for
  # fibers whose canonical store is project-scoped (e.g. lightcone). Fix:
  # thread the resolved host through invoke_action and prepend
  # `--felt-store <host>` to every shuttle-ctl invocation.
  @tag :capture_log
  test "actions invoke passes --felt-store to shuttle-ctl" do
    with_actions_host()
    # An awaiting-review fiber so close-tempered is an available action.
    MockRunner.set_shuttle(
      "tests/action-felt-store",
      "enabled: true\nkind: oneshot\nreview:\n  state: awaiting\n",
      "closed"
    )

    # Stand up a fake shuttle-ctl on PATH that records its argv and exits 0.
    stub_dir =
      Path.join(System.tmp_dir!(), "shuttle-test-stub-#{System.unique_integer([:positive])}")

    File.mkdir_p!(stub_dir)
    argv_log = Path.join(stub_dir, "argv.log")

    File.write!(Path.join(stub_dir, "shuttle-ctl"), """
    #!/usr/bin/env bash
    printf '%s\\n' "$@" >> "#{argv_log}"
    exit 0
    """)

    File.chmod!(Path.join(stub_dir, "shuttle-ctl"), 0o755)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", "#{stub_dir}:#{previous_path}")

    on_exit(fn ->
      if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH")
      File.rm_rf!(stub_dir)
    end)

    conn =
      post(
        api_conn(),
        "/api/v1/actions/invoke",
        Jason.encode!(%{fiber_id: "tests/action-felt-store", action: "close-tempered"})
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["invoked"] == true

    captured = argv_log |> File.read!() |> String.split("\n", trim: true)
    # `--felt-store /tmp` must come before the verb so shuttle-ctl uses the
    # store the daemon resolved against, not its own default discovery.
    assert Enum.take(captured, 2) == ["--felt-store", "/tmp"]
    assert "close" in captured
    assert "tests/action-felt-store" in captured
    assert "--tempered=true" in captured
  end

  # ── POST /api/v1/wait ──

  test "wait returns monitoring for active fiber" do
    fiber = make_fiber("tests/wait-active")
    MockRunner.set_fiber("tests/wait-active", fiber)

    conn =
      post(
        api_conn(),
        "/api/v1/wait",
        Jason.encode!(%{
          "fiber_id" => "tests/wait-active",
          "timeout_ms" => 5000
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["accepted"] == true
    assert body["status"] == "monitoring"
    assert body["channel_topic"] == "shuttle:wait:tests/wait-active"
  end

  test "wait returns already_tempered for tempered fiber" do
    fiber = make_fiber("tests/wait-tempered", %{"tempered" => true})
    MockRunner.set_fiber("tests/wait-tempered", fiber)

    conn =
      post(
        api_conn(),
        "/api/v1/wait",
        Jason.encode!(%{
          "fiber_id" => "tests/wait-tempered"
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["accepted"] == true
    assert body["status"] == "already_tempered"
  end

  test "wait channel receives tempered event" do
    fiber = make_fiber("tests/wait-channel")
    MockRunner.set_fiber("tests/wait-channel", fiber)

    conn =
      post(
        api_conn(),
        "/api/v1/wait",
        Jason.encode!(%{
          "fiber_id" => "tests/wait-channel",
          "timeout_ms" => 5_000
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{}, connect_info: %{})
    {:ok, _reply, _channel_socket} = subscribe_and_join(socket, body["channel_topic"], %{})

    MockRunner.set_fiber("tests/wait-channel", Map.put(fiber, "tempered", true))
    send(Shuttle.Poller, :run_poll_cycle)

    assert_push("tempered", payload, 500)
    assert payload.fiber_id == "tests/wait-channel"
  end

  test "wait channel receives timeout event" do
    fiber = make_fiber("tests/wait-timeout")
    MockRunner.set_fiber("tests/wait-timeout", fiber)

    conn =
      post(
        api_conn(),
        "/api/v1/wait",
        Jason.encode!(%{
          "fiber_id" => "tests/wait-timeout",
          "timeout_ms" => 20
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{}, connect_info: %{})
    {:ok, _reply, _channel_socket} = subscribe_and_join(socket, body["channel_topic"], %{})

    assert_push("timed_out", payload, 500)
    assert payload.fiber_id == "tests/wait-timeout"
  end

  # ── POST /api/v1/reserve ──

  test "reserve succeeds for available resource" do
    conn =
      post(
        api_conn(),
        "/api/v1/reserve",
        Jason.encode!(%{
          "resource" => "gpu",
          "host" => "candide",
          "duration_ms" => 3_600_000,
          "fiber_id" => "tests/reserve-gpu"
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["reserved"] == true
    assert body["resource"] == "gpu"
    assert body["fiber_id"] == "tests/reserve-gpu"
  end

  test "reserve returns 409 for already reserved resource" do
    post(
      api_conn(),
      "/api/v1/reserve",
      Jason.encode!(%{
        "resource" => "gpu",
        "host" => "candide",
        "duration_ms" => 3_600_000,
        "fiber_id" => "tests/reserve-gpu-first"
      })
    )

    conn =
      post(
        api_conn(),
        "/api/v1/reserve",
        Jason.encode!(%{
          "resource" => "gpu",
          "host" => "candide",
          "duration_ms" => 3_600_000,
          "fiber_id" => "tests/reserve-gpu-second"
        })
      )

    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)
    assert body["reserved"] == false
    assert body["reason"] =~ "already reserved"
  end

  test "reserve returns 400 without resource or fiber_id" do
    conn =
      post(
        api_conn(),
        "/api/v1/reserve",
        Jason.encode!(%{
          "fiber_id" => "tests/missing-resource"
        })
      )

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "resource and fiber_id are required"
  end

  # ── GET /api/v1/state ──

  test "state returns full orchestrator state" do
    fiber = make_fiber("tests/state")
    MockRunner.set_fiber("tests/state", fiber)
    MockRunner.set_shuttle("tests/state", @oneshot_shuttle)

    send(Shuttle.Poller, :run_poll_cycle)
    Process.sleep(100)

    conn = get(api_conn(), "/api/v1/state")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["host"] != nil
    assert is_list(body["eligible"])
    assert is_list(body["running_detail"])
    assert is_list(body["reservations"])
    assert is_list(body["waiters"])
  end

  test "state degrades to JSON when the poller is unavailable" do
    :sys.suspend(Shuttle.Poller)

    try do
      conn = get(api_conn(), "/api/v1/state")
      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "poller_unavailable"
      assert is_binary(body["host"])
      assert is_list(body["running_detail"])
    after
      :sys.resume(Shuttle.Poller)
    end
  end

  # ── GET /api/v1/state/composite ──

  test "composite returns local snapshot plus per-origin remote snapshots" do
    # Spin up a RemoteRegistry with a stub client so the composite
    # endpoint has remote data to merge in. The client returns a fake
    # candide snapshot that lists tests/work-on-candide as running.
    defmodule CompositeStubClient do
      @behaviour Shuttle.RemoteRegistry.Client

      @impl true
      def get("http://localhost:4001/api/v1/state", _timeout) do
        body =
          Jason.encode!(%{
            "host" => "candide",
            "eligible" => [%{"fiber_id" => "tests/work-on-candide"}],
            "blocked" => [],
            "retrying" => []
          })

        {:ok, body}
      end

      def get(_url, _timeout), do: {:error, :no_stub}
    end

    # Controller calls Shuttle.RemoteRegistry.snapshots/0, which routes
    # to the default-named GenServer. Start one under the default name
    # for this test (the test config disables auto-start so this name
    # is free until we claim it).
    start_supervised!({
      Shuttle.RemoteRegistry,
      remotes: [
        %Shuttle.Remote{name: "candide", url: "http://localhost:4001"}
      ],
      client: CompositeStubClient,
      tick_interval_ms: 60_000
    })

    :ok = Shuttle.RemoteRegistry.poll_now()

    conn = get(api_conn(), "/api/v1/state/composite")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert is_map(body["local"])
    assert is_list(body["local"]["eligible"])

    assert is_map(body["remotes"])
    candide = body["remotes"]["candide"]
    assert candide != nil
    assert candide["stale"] == false
    assert candide["last_polled_at"] != nil
    assert candide["last_error"] == nil
    assert is_map(candide["snapshot"])
    assert candide["snapshot"]["host"] == "candide"
    assert candide["recovery"]["state"] == "healthy"
    assert candide["recovery"]["attempt"] == 0
  end

  test "composite degrades remote snapshots when the remote registry is unavailable" do
    start_supervised!({
      Shuttle.RemoteRegistry,
      remotes: [
        %Shuttle.Remote{name: "candide", url: "http://localhost:4001"}
      ],
      tick_interval_ms: 60_000
    })

    :sys.suspend(Shuttle.RemoteRegistry)

    try do
      conn = get(api_conn(), "/api/v1/state/composite")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["remotes"]["_registry"]["stale"] == true
      assert body["remotes"]["_registry"]["last_error"] != nil
      assert body["remotes"]["_registry"]["recovery"]["state"] == "unavailable"
    after
      :sys.resume(Shuttle.RemoteRegistry)
    end
  end

  test "composite degrades gracefully when no RemoteRegistry is running" do
    # No RemoteRegistry started under the default name; controller
    # should still return a valid composite shape.
    conn = get(api_conn(), "/api/v1/state/composite")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert is_map(body["local"])
    assert body["remotes"] == %{}
  end

  test "composite degrades local snapshot when the poller is unavailable" do
    :sys.suspend(Shuttle.Poller)

    try do
      conn = get(api_conn(), "/api/v1/state/composite")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["local"]["error"] == "poller_unavailable"
      assert body["remotes"] == %{}
    after
      :sys.resume(Shuttle.Poller)
    end
  end

  # ── GET /api/v1/agents ──

  test "agents returns the registry as a JSON array" do
    conn = get(api_conn(), "/api/v1/agents")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_list(body)
    assert length(body) > 0

    # Each record carries the registry's stable shape.
    [first | _] = body
    assert is_binary(first["id"])
    assert is_binary(first["cli"])
    assert is_binary(first["wrapper"])

    # Default agent (claude-sonnet at the time of writing) is present and flagged.
    default = Enum.find(body, & &1["default"])
    assert default != nil
    assert is_binary(default["id"])
  end

  # ── GET /api/v1/version ──

  test "version returns the daemon build-info shape" do
    conn = get(api_conn(), "/api/v1/version")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert is_binary(body["git_sha"])
    assert is_binary(body["git_short_sha"])
    assert is_binary(body["built_at"])
    assert body["mix_vsn"] == Shuttle.version()

    if body["git_sha"] != "unknown" do
      assert String.length(body["git_short_sha"]) == 7
      assert String.starts_with?(body["git_sha"], body["git_short_sha"])
    end
  end

  # ── Worker Channel ──

  test "worker channel broadcasts exit events" do
    fiber = make_fiber("tests/channel")
    MockRunner.set_fiber("tests/channel", fiber)
    MockRunner.set_shuttle("tests/channel", @oneshot_shuttle)

    send(Shuttle.Poller, :run_poll_cycle)
    Process.sleep(100)

    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{}, connect_info: %{})

    {:ok, _reply, _channel_socket} =
      subscribe_and_join(socket, "shuttle:worker:tests/channel", %{})

    MockRunner.remove_tmux_session(Dispatcher.session_name("tests/channel"))
    send(Shuttle.Poller, {:worker_exited, "tests/channel", :normal_exit, false})

    assert_push("worker_exited", payload, 500)
    assert payload.fiber_id == "tests/channel"
  end
end
