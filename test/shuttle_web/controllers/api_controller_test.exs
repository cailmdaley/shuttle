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

    # Carry a felt-style absolute `path` so the poller's store-ownership check
    # (which reads felt's `path`) sees the fiber as rooted in `/tmp`. Mirrors
    # real felt, which now emits `path` on every listed/shown fiber.
    def set_fiber(id, fiber) do
      Agent.update(__MODULE__, fn state ->
        existing_path = get_in(state.fibers, [id, "path"])
        path = Map.get(fiber, "path") || existing_path || synth_path(id)
        put_in(state.fibers[id], Map.put(fiber, "path", path))
      end)
    end

    defp synth_path(id) do
      leaf = id |> String.split("/") |> List.last()
      resolve_tmp_symlink(Path.expand(Path.join(["/tmp/.felt", id, "#{leaf}.md"])))
    end

    defp resolve_tmp_symlink("/tmp/" <> rest), do: "/private/tmp/" <> rest
    defp resolve_tmp_symlink("/var/" <> rest), do: "/private/var/" <> rest
    defp resolve_tmp_symlink(path), do: path

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

      carried_path = synth_path(id)

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

  # POST transport stub for the cross-host /transition forward test. Records the
  # last (url, body) it was asked to POST and replays a scripted response, so the
  # forward leg is exercised without a real tunnel. Implements `post/4` only —
  # the read `get/2` callback isn't needed here, so it doesn't declare the
  # behaviour (which would warn about the missing required `get/2`).
  defmodule StubPostClient do
    use Agent

    def start_link(_ \\ []),
      do: Agent.start_link(fn -> %{response: nil, last: nil} end, name: __MODULE__)

    def set_response(response), do: Agent.update(__MODULE__, &Map.put(&1, :response, response))
    def last, do: Agent.get(__MODULE__, & &1.last)

    def post(url, body, _content_type, _timeout_ms) do
      Agent.update(__MODULE__, &Map.put(&1, :last, %{url: url, body: body}))
      Agent.get(__MODULE__, & &1.response)
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

  defp restore_app_env(key, nil), do: Application.delete_env(:shuttle, key)
  defp restore_app_env(key, value), do: Application.put_env(:shuttle, key, value)

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

  test "HTTP ad-hoc dispatch of an awaiting standing role re-arms and runs (no longer 422)" do
    # Awaiting is felt-native (slice 5): status:closed + untempered. The HTTP
    # /dispatch path folds ad_hoc into force (`force: force or ad_hoc`), so an
    # explicit dispatch IS the human verdict: it bypasses the awaiting gate,
    # re-arms the doc, and spawns — instead of the old 422 that told the user to
    # `shuttle-ctl accept/resume` first. (The autonomous poller, which calls
    # dispatch_fiber in-process with ad_hoc and NOT force, is still gated — see
    # PollerTest "ad-hoc dispatch refuses an awaiting standing role only when NOT
    # forced".)
    fiber_id = "tests/api-awaiting-refuses-adhoc"

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

    conn =
      post(
        api_conn(),
        "/api/v1/dispatch",
        Jason.encode!(%{
          "fiber_id" => fiber_id,
          "ad_hoc" => true
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["dispatched"] == true
    assert body["fiber_id"] == fiber_id
  end

  # ── Shuttle actions ──

  @tag :capture_log
  test "actions resolve returns the canonical lifecycle action via the Poller" do
    with_actions_host()

    # Awaiting is felt-native (slice 5): status:closed + untempered standing.
    MockRunner.set_shuttle(
      "tests/action-awaiting",
      "kind: standing\n",
      "closed"
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

    # Resolution runs through the Poller, which fetches the fiber rather than
    # parsing the frontmatter inline in the controller.
    assert Enum.any?(MockRunner.commands(), fn {command, args} ->
             command == "felt" and "show" in args
           end)
  end

  # Inline-fiber mode: the caller (Portolan) already has the fiber map in
  # memory — e.g. for a remote-origin transition where the fiber lives on a
  # different host than the daemon can see. Skip the disk lookup and resolve
  # purely from the supplied map.
  @tag :capture_log
  test "actions resolve accepts an inline fiber map and skips disk lookup" do
    # Awaiting is felt-native (slice 5): status:closed + untempered standing.
    inline_fiber = %{
      "id" => "remote/host/standing-awaiting",
      "status" => "closed",
      "shuttle" => %{"kind" => "standing"}
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

  # overnight-audit C10 / finding 3: the inline-fiber resolve clause validated
  # only `is_map(fiber)`, never the shape of fiber["shuttle"] / ["review"]. A
  # non-map shuttle raised BadMapError; a scalar/list review raised
  # FunctionClauseError — both bubbling to a bare Phoenix 500 where a graceful
  # response is the documented contract. The accessors are now total.
  @tag :capture_log
  test "actions resolve degrades a malformed shuttle/review shape instead of 500ing" do
    malformed = [
      %{"id" => "x", "status" => "open", "shuttle" => "enabled"},
      %{"id" => "x", "status" => "open", "shuttle" => [1, 2]},
      %{"id" => "x", "status" => "open", "shuttle" => 7},
      %{
        "id" => "x",
        "status" => "open",
        "shuttle" => %{"enabled" => true, "kind" => "standing", "review" => "awaiting"}
      },
      %{
        "id" => "x",
        "status" => "open",
        "shuttle" => %{"enabled" => true, "kind" => "standing", "review" => ["awaiting"]}
      },
      %{
        "id" => "x",
        "status" => "open",
        "shuttle" => %{"enabled" => true, "kind" => "standing", "review" => 3}
      }
    ]

    for fiber <- malformed do
      conn =
        post(
          api_conn(),
          "/api/v1/actions/resolve",
          Jason.encode!(%{fiber: fiber, target: "tempered"})
        )

      # Graceful: a resolved action (degraded to the default path), never a 500.
      assert conn.status == 200, "expected graceful 200 for #{inspect(fiber)}, got #{conn.status}"
      assert Jason.decode!(conn.resp_body)["action"]["id"] != nil
    end
  end

  # Controls: well-formed shapes still resolve correctly after the hardening.
  @tag :capture_log
  test "actions resolve controls: well-formed shapes still resolve correctly" do
    # An armed oneshot (status: active) dragged to inFlight launches it
    # (dispatch-ad-hoc). A stray review key in the block is irrelevant (slice 5).
    nonstanding =
      post(
        api_conn(),
        "/api/v1/actions/resolve",
        Jason.encode!(%{
          fiber: %{
            "id" => "x",
            "status" => "active",
            "shuttle" => %{"kind" => "oneshot", "review" => "awaiting"}
          },
          target: "inFlight"
        })
      )

    assert nonstanding.status == 200
    assert Jason.decode!(nonstanding.resp_body)["action"]["id"] == "dispatch-ad-hoc"

    # A well-formed awaiting standing role (status:closed + untempered) still
    # resolves accept-run.
    standing =
      post(
        api_conn(),
        "/api/v1/actions/resolve",
        Jason.encode!(%{
          fiber: %{
            "id" => "x",
            "status" => "closed",
            "shuttle" => %{"kind" => "standing"}
          },
          target: "tempered"
        })
      )

    assert standing.status == 200
    assert Jason.decode!(standing.resp_body)["action"]["id"] == "accept-run"
  end

  # Single-source invariant (C1/C2 dual-source fix). The by-fiber-id resolve
  # (`Poller.resolve_action`) and the by-fiber-id availability
  # (`Poller.actions_for`, which `validate_available` gates on) BOTH derive
  # `running?` from `state.running` and overlay the runtime lifecycle from the
  # SAME state — so for a RUNNING fiber, every resolved action is guaranteed to
  # be in the availability set. Portolan routes local daemon-owned transitions
  # through this by-id path precisely so resolve ⊆ availability holds across the
  # process boundary; the inline-fiber path can't promise this because its
  # `running?`/`review.state` are caller-supplied and may disagree with the
  # daemon's registry. This pins that no kanban target can resolve to an action
  # the invoke leg then rejects with 409 for a running fiber.
  @tag :capture_log
  test "by-fiber-id resolve ⊆ availability for a RUNNING fiber across all kanban targets" do
    with_actions_host()
    fiber_id = "tests/action-running-single-source"
    MockRunner.set_fiber(fiber_id, make_fiber(fiber_id))
    MockRunner.set_shuttle(fiber_id, @oneshot_shuttle)

    # Dispatch synchronously populates state.running — the daemon's worker
    # registry now holds a live worker for this fiber.
    assert {:ok, _session} = Poller.dispatch_fiber(fiber_id, [])

    # Availability is the daemon's running-branch set (no reopen/dispatch-ad-hoc).
    avail_conn = get(api_conn(), "/api/v1/actions/#{fiber_id}")
    assert avail_conn.status == 200

    available_ids =
      avail_conn.resp_body |> Jason.decode!() |> Map.fetch!("actions") |> Enum.map(& &1["id"])

    # Sanity: a running fiber's set is pause + close-*, never reopen.
    assert "pause" in available_ids
    refute "reopen" in available_ids

    for target <- ["drafts", "inFlight", "awaitingReview", "tempered", "composted"] do
      resolve_conn =
        post(
          api_conn(),
          "/api/v1/actions/resolve",
          Jason.encode!(%{fiber_id: fiber_id, target: target})
        )

      assert resolve_conn.status == 200, "resolve #{target} should 200 for a running owned fiber"
      action_id = resolve_conn.resp_body |> Jason.decode!() |> get_in(["action", "id"])

      # The by-construction invariant: a resolved action MUST be invocable. This
      # is the contract Portolan's by-fiber-id routing relies on — both legs read
      # one source, so resolve ⊆ availability and the invoke never 409s.
      assert action_id in available_ids,
             "running fiber: resolve(#{target})=#{action_id} not in availability #{inspect(available_ids)}"
    end
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

  test "actions invoke for an unknown fiber returns 404, matching show/resolve" do
    with_actions_host()

    conn =
      post(
        api_conn(),
        "/api/v1/actions/invoke",
        Jason.encode!(%{fiber_id: "tests/does-not-exist", action: "pause"})
      )

    # Was a bare 500; the read paths (show / resolve) already 404 for an
    # unknown fiber, so invoke matches them. (overnight-audit C1+C10 error UX.)
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "not_found"
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

  # ── POST /api/v1/transition ──

  # The unified write-plane: one call resolves the kanban target to an action
  # AND invokes it (no separate resolve leg). A closed oneshot dragged to the
  # tempered column resolves to close-tempered and shells the offline writer —
  # threading --felt-store through the extracted Transition pipeline.
  @tag :capture_log
  test "transition resolves the target and invokes in one call (local)" do
    with_actions_host()

    MockRunner.set_shuttle(
      "tests/transition-local",
      "enabled: true\nkind: oneshot\nreview:\n  state: awaiting\n",
      "closed"
    )

    stub_dir =
      Path.join(System.tmp_dir!(), "shuttle-transition-stub-#{System.unique_integer([:positive])}")

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
        "/api/v1/transition",
        Jason.encode!(%{fiber_id: "tests/transition-local", target: "tempered"})
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["invoked"] == true
    assert body["action"] == "close-tempered"
    assert body["target"] == "tempered"

    captured = argv_log |> File.read!() |> String.split("\n", trim: true)
    assert Enum.take(captured, 2) == ["--felt-store", "/tmp"]
    assert "close" in captured
    assert "--tempered=true" in captured
  end

  test "transition for an unknown target returns 400" do
    with_actions_host()
    MockRunner.set_shuttle("tests/transition-bad-target", @oneshot_shuttle)

    conn =
      post(
        api_conn(),
        "/api/v1/transition",
        Jason.encode!(%{fiber_id: "tests/transition-bad-target", target: "nowhere"})
      )

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "unknown_target"
    assert body["invoked"] == false
  end

  test "transition for an unknown fiber returns 404" do
    with_actions_host()

    conn =
      post(
        api_conn(),
        "/api/v1/transition",
        Jason.encode!(%{fiber_id: "tests/transition-missing", target: "drafts"})
      )

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "not_found"
    assert body["invoked"] == false
  end

  # A remote-owned fiber: the local daemon forwards to the OWNING remote's
  # /transition over the tunnel and relays its response verbatim, re-stamped with
  # the origin the caller routed to. The forwarded payload carries no origin (so
  # the remote runs its own local branch); only fiber_id + target cross the wire.
  test "transition forwards a remote-owned fiber to the owning daemon" do
    start_supervised!(StubPostClient)

    StubPostClient.set_response(
      {:ok, 200,
       Jason.encode!(%{
         "fiber_id" => "tests/remote-work",
         "target" => "drafts",
         "origin" => "local",
         "action" => "pause",
         "invoked" => true
       })}
    )

    previous_remotes = Application.get_env(:shuttle, :remotes)
    previous_client = Application.get_env(:shuttle, :write_forward_client)
    Application.put_env(:shuttle, :remotes, [%{name: "candide", url: "http://localhost:4001"}])
    Application.put_env(:shuttle, :write_forward_client, StubPostClient)

    on_exit(fn ->
      restore_app_env(:remotes, previous_remotes)
      restore_app_env(:write_forward_client, previous_client)
    end)

    conn =
      post(
        api_conn(),
        "/api/v1/transition",
        Jason.encode!(%{
          fiber_id: "tests/remote-work",
          target: "drafts",
          origin: "candide"
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["invoked"] == true
    assert body["action"] == "pause"
    # Origin re-stamped to what the caller routed to, not the remote's "local".
    assert body["origin"] == "candide"

    # Forwarded to the owning remote's /transition, fiber_id + target only.
    last = StubPostClient.last()
    assert last.url == "http://localhost:4001/api/v1/transition"
    forwarded = Jason.decode!(last.body)
    assert forwarded == %{"fiber_id" => "tests/remote-work", "target" => "drafts"}
  end

  test "transition relays a remote owner's error status" do
    start_supervised!(StubPostClient)

    StubPostClient.set_response(
      {:ok, 409, Jason.encode!(%{"invoked" => false, "error" => "action_not_available"})}
    )

    previous_remotes = Application.get_env(:shuttle, :remotes)
    previous_client = Application.get_env(:shuttle, :write_forward_client)
    Application.put_env(:shuttle, :remotes, [%{name: "cineca", url: "http://localhost:4002"}])
    Application.put_env(:shuttle, :write_forward_client, StubPostClient)

    on_exit(fn ->
      restore_app_env(:remotes, previous_remotes)
      restore_app_env(:write_forward_client, previous_client)
    end)

    conn =
      post(
        api_conn(),
        "/api/v1/transition",
        Jason.encode!(%{fiber_id: "tests/remote-err", target: "tempered", origin: "cineca"})
      )

    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)
    assert body["invoked"] == false
    assert body["error"] == "action_not_available"
    assert body["origin"] == "cineca"
  end

  # ── Owner-routing for the non-drag write verbs (Shuttle.OriginRouter) ──
  #
  # The kanban posts tag/horizon edits, promote/requeue lifecycle, and
  # review-comment history directly to Shuttle, carrying the `origin` the
  # composite board stamped. A remote-owned card forwards to the owning daemon's
  # IDENTICAL endpoint over the tunnel (origin stripped, so the owner runs its
  # own local branch) and relays the response verbatim — the same one-hop shape
  # /transition uses, via the shared forwarder.

  defp stub_forward(remote_name, remote_url, response) do
    start_supervised!(StubPostClient)
    StubPostClient.set_response(response)

    previous_remotes = Application.get_env(:shuttle, :remotes)
    previous_client = Application.get_env(:shuttle, :write_forward_client)
    Application.put_env(:shuttle, :remotes, [%{name: remote_name, url: remote_url}])
    Application.put_env(:shuttle, :write_forward_client, StubPostClient)

    on_exit(fn ->
      restore_app_env(:remotes, previous_remotes)
      restore_app_env(:write_forward_client, previous_client)
    end)
  end

  test "felt-edit forwards a remote-owned card to the owning daemon" do
    stub_forward("candide", "http://localhost:4001", {:ok, 200, "edited"})

    conn =
      post(
        api_conn(),
        "/api/v1/felt-edit",
        Jason.encode!(%{fiber_id: "tests/remote-card", origin: "candide", add: ["idea"]})
      )

    assert conn.status == 200
    assert conn.resp_body == "edited"

    last = StubPostClient.last()
    assert last.url == "http://localhost:4001/api/v1/felt-edit"
    # origin stripped so the owner treats the fiber as local; the rest crosses.
    assert Jason.decode!(last.body) == %{"fiber_id" => "tests/remote-card", "add" => ["idea"]}
  end

  test "lifecycle forwards a remote-owned card to the owning daemon" do
    stub_forward("candide", "http://localhost:4001", {:ok, 200, "paused"})

    conn =
      post(
        api_conn(),
        "/api/v1/lifecycle",
        Jason.encode!(%{action: "pause", fiber: "tests/remote-card", origin: "candide"})
      )

    assert conn.status == 200
    assert conn.resp_body == "paused"

    last = StubPostClient.last()
    assert last.url == "http://localhost:4001/api/v1/lifecycle"
    assert Jason.decode!(last.body) == %{"action" => "pause", "fiber" => "tests/remote-card"}
  end

  test "felt-history forwards a remote-owned card to the owning daemon" do
    stub_forward("cineca", "http://localhost:4002", {:ok, 200, "appended"})

    conn =
      post(
        api_conn(),
        "/api/v1/felt-history",
        Jason.encode!(%{
          fiber_id: "tests/remote-card",
          kind: "review-comment",
          summary: "do the thing",
          origin: "cineca"
        })
      )

    assert conn.status == 200
    assert conn.resp_body == "appended"

    last = StubPostClient.last()
    assert last.url == "http://localhost:4002/api/v1/felt-history"

    assert Jason.decode!(last.body) == %{
             "fiber_id" => "tests/remote-card",
             "kind" => "review-comment",
             "summary" => "do the thing"
           }
  end

  test "dispatch forwards a remote-owned card and relays its JSON" do
    stub_forward(
      "candide",
      "http://localhost:4001",
      {:ok, 200, Jason.encode!(%{"dispatched" => true, "fiber_id" => "tests/remote-card"})}
    )

    conn =
      post(
        api_conn(),
        "/api/v1/dispatch",
        Jason.encode!(%{fiber_id: "tests/remote-card", origin: "candide"})
      )

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["dispatched"] == true

    last = StubPostClient.last()
    assert last.url == "http://localhost:4001/api/v1/dispatch"
    assert Jason.decode!(last.body) == %{"fiber_id" => "tests/remote-card"}
  end

  test "felt-edit relays a tunnel failure as 502" do
    stub_forward("candide", "http://localhost:4001", {:error, :econnrefused})

    conn =
      post(
        api_conn(),
        "/api/v1/felt-edit",
        Jason.encode!(%{fiber_id: "tests/remote-card", origin: "candide", add: ["x"]})
      )

    assert conn.status == 502
    assert conn.resp_body =~ "forward to candide failed"
  end

  test "an unknown origin falls through to local — no forward, local arbitrates" do
    stub_forward("candide", "http://localhost:4001", {:ok, 200, "should-not-be-used"})

    # origin "ghost" matches no configured remote → :local. The fiber isn't in
    # the local store, so the local branch returns a clean not-found rather than
    # forwarding anywhere.
    conn =
      post(
        api_conn(),
        "/api/v1/felt-edit",
        Jason.encode!(%{fiber_id: "tests/nonexistent", origin: "ghost", add: ["x"]})
      )

    assert conn.status == 400
    assert conn.resp_body =~ "fiber not found"
    # The forwarder was never touched — no silent mis-route to the wrong host.
    assert StubPostClient.last() == nil
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
    uid = "01KTCA2CWXBSNHETE66MXKPVE7"
    fiber = make_fiber("tests/state", %{"uid" => uid})
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

    # Slice 7: no separate `:runtime` index. Liveness rides the `eligible` rows
    # — each carries the intrinsic uid, the live tmux session, and run state, so
    # a consumer reads running-ness off the row instead of joining against a
    # parallel runtime overlay (which the cutover deleted with the store).
    refute Map.has_key?(body, "runtime")

    expected_session = "state-#{uid}-shuttle"

    assert [
             %{
               "fiber_id" => "tests/state",
               "uid" => ^uid,
               "state" => "running",
               "tmux_session" => ^expected_session
             }
           ] = body["eligible"]

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
