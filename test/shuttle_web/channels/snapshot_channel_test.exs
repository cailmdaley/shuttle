defmodule ShuttleWeb.SnapshotChannelTest do
  use ExUnit.Case
  import Phoenix.ChannelTest

  @endpoint ShuttleWeb.Endpoint

  alias ShuttleWeb.UserSocket
  alias Shuttle.Poller

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
            felt_ls: []
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
          felt_ls: []
        }
      end)
    end

    def set_fiber(id, fiber), do: Agent.update(__MODULE__, &put_in(&1.fibers[id], fiber))

    # Write a real .md file carrying the given shuttle: block and felt status so
    # that walk_shuttle_fibers (the file-walk discovery path) can find it. The
    # status defaults to "active" — pass an explicit value for tests that verify
    # eligibility gates (closed, untracked, etc.).
    def set_shuttle(id, yaml, status \\ "active") do
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

    @impl true
    def cmd(command, args, _opts) do
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

  setup do
    start_supervised!(MockRunner)
    MockRunner.reset()
    :ok
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

  # Minimal shuttle: block YAML for a oneshot fiber ready for dispatch.
  @oneshot_shuttle "enabled: true\nkind: oneshot\n"

  test "snapshot channel sends current snapshot on join" do
    fiber = make_fiber("tests/haiku")
    MockRunner.set_fiber("tests/haiku", fiber)
    MockRunner.set_shuttle("tests/haiku", @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Trigger dispatch
    send(poller, :run_poll_cycle)
    Process.sleep(100)

    # Connect socket and join channel
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{})
    {:ok, payload, _socket} = subscribe_and_join(socket, "shuttle:snapshot", %{})

    assert is_binary(payload.host)
    assert length(payload.eligible) == 1
    assert hd(payload.eligible).fiber_id == "tests/haiku"
  end

  test "snapshot channel broadcasts on state change" do
    fiber = make_fiber("tests/haiku")
    MockRunner.set_fiber("tests/haiku", fiber)
    MockRunner.set_shuttle("tests/haiku", @oneshot_shuttle)

    {:ok, poller} =
      Poller.start_link(
        runner: MockRunner,
        poll_interval_ms: 60_000,
        felt_stores: ["/tmp"]
      )

    # Connect and join
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{})
    {:ok, _payload, _socket} = subscribe_and_join(socket, "shuttle:snapshot", %{})

    # Trigger dispatch — should broadcast
    send(poller, :run_poll_cycle)

    assert_push("snapshot", payload, 500)
    assert length(payload.eligible) == 1
    assert hd(payload.eligible).fiber_id == "tests/haiku"
  end
end
