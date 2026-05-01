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
      Agent.start_link(fn -> %{
        commands: [],
        tmux_sessions: MapSet.new(),
        fibers: %{},
        felt_ls: []
      } end, name: __MODULE__)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{
        commands: [],
        tmux_sessions: MapSet.new(),
        fibers: %{},
        felt_ls: []
      } end)
    end

    def set_fiber(id, fiber), do: Agent.update(__MODULE__, &put_in(&1.fibers[id], fiber))
    def set_felt_ls(fibers), do: Agent.update(__MODULE__, &%{&1 | felt_ls: fibers})
    def add_tmux_session(session), do: Agent.update(__MODULE__, &%{&1 | tmux_sessions: MapSet.put(&1.tmux_sessions, session)})
    def remove_tmux_session(session), do: Agent.update(__MODULE__, &%{&1 | tmux_sessions: MapSet.delete(&1.tmux_sessions, session)})

    @impl true
    def cmd(command, args, _opts) do
      full_args = Enum.join(args, " ")

      cond do
        command == "felt" and String.contains?(full_args, "ls") ->
          fibers = Agent.get(__MODULE__, & &1.felt_ls)
          {Jason.encode!(fibers), 0}

        command == "felt" and String.contains?(full_args, "show") ->
          fiber_id = Enum.find(args, "", fn arg -> arg != "show" and arg != "--json" end)
          fibers = Agent.get(__MODULE__, & &1.fibers)

          case Map.get(fibers, fiber_id) do
            nil -> {"fiber not found", 1}
            fiber -> {Jason.encode!(fiber), 0}
          end

        command == "tmux" and hd(args) == "has-session" ->
          session = Enum.at(args, 2)
          sessions = Agent.get(__MODULE__, & &1.tmux_sessions)

          if MapSet.member?(sessions, session) do
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
  end

  setup do
    start_supervised!(MockRunner)
    MockRunner.reset()
    :ok
  end

  defp make_fiber(id, attrs \\ %{}) do
    Map.merge(%{
      "id" => id,
      "name" => id,
      "status" => "active",
      "tags" => ["constitution"],
      "created_at" => "2026-04-28T00:00:00Z"
    }, attrs)
  end

  test "snapshot channel sends current snapshot on join" do
    fiber = make_fiber("tests/haiku")
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/haiku", fiber)

    {:ok, poller} = Poller.start_link(
      runner: MockRunner,
      poll_interval_ms: 60_000,
      felt_host: "/tmp"
    )

    # Trigger dispatch
    send(poller, :run_poll_cycle)
    Process.sleep(100)

    # Connect socket and join channel
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{})
    {:ok, payload, _socket} = subscribe_and_join(socket, "shuttle:snapshot", %{})

    assert payload.host == "dapmcw68"
    assert length(payload.eligible) == 1
    assert hd(payload.eligible).fiber_id == "tests/haiku"
  end

  test "snapshot channel broadcasts on state change" do
    fiber = make_fiber("tests/haiku")
    MockRunner.set_felt_ls([fiber])
    MockRunner.set_fiber("tests/haiku", fiber)

    {:ok, poller} = Poller.start_link(
      runner: MockRunner,
      poll_interval_ms: 60_000,
      felt_host: "/tmp"
    )

    # Connect and join
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{})
    {:ok, _payload, _socket} = subscribe_and_join(socket, "shuttle:snapshot", %{})

    # Trigger dispatch — should broadcast
    send(poller, :run_poll_cycle)

    assert_broadcast "snapshot", payload, 500
    assert length(payload.eligible) == 1
    assert hd(payload.eligible).fiber_id == "tests/haiku"
  end
end
