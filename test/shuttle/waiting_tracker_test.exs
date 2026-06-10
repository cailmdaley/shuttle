defmodule Shuttle.WaitingTrackerTest do
  use ExUnit.Case, async: false

  alias Shuttle.WaitingTracker

  setup do
    base = Path.join(System.tmp_dir!(), "waiting_tracker_#{System.unique_integer([:positive])}")
    events = base <> ".jsonl"
    File.write!(events, "")
    on_exit(fn -> File.rm(events) end)
    {:ok, events: events}
  end

  defp start(events) do
    name = :"waiting_tracker_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      WaitingTracker.start_link(events_file: events, poll_interval_ms: 10, name: name)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  defp append(events, type, session) do
    line = Jason.encode!(%{type: type, tmuxSession: session})
    File.write!(events, line <> "\n", [:append])
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries <= 0 -> false
      true -> Process.sleep(10); wait_until(fun, tries - 1)
    end
  end

  test "a Notification event marks the session waiting", %{events: events} do
    name = start(events)
    append(events, "notification", "foo-01J-shuttle")

    assert wait_until(fn -> MapSet.member?(WaitingTracker.waiting_sessions(name), "foo-01J-shuttle") end)
  end

  test "subsequent activity clears the waiting state", %{events: events} do
    name = start(events)
    append(events, "notification", "foo-01J-shuttle")
    assert wait_until(fn -> MapSet.member?(WaitingTracker.waiting_sessions(name), "foo-01J-shuttle") end)

    append(events, "post_tool_use", "foo-01J-shuttle")
    assert wait_until(fn -> not MapSet.member?(WaitingTracker.waiting_sessions(name), "foo-01J-shuttle") end)
  end

  test "a Stop event also clears the waiting state", %{events: events} do
    name = start(events)
    append(events, "notification", "foo-01J-shuttle")
    assert wait_until(fn -> MapSet.member?(WaitingTracker.waiting_sessions(name), "foo-01J-shuttle") end)

    append(events, "stop", "foo-01J-shuttle")
    assert wait_until(fn -> not MapSet.member?(WaitingTracker.waiting_sessions(name), "foo-01J-shuttle") end)
  end

  test "non-shuttle sessions are ignored", %{events: events} do
    name = start(events)
    append(events, "notification", "my-interactive-session")
    # Give the tailer a couple of cycles to ingest.
    Process.sleep(40)
    refute MapSet.member?(WaitingTracker.waiting_sessions(name), "my-interactive-session")
  end

  test "historical notifications before boot are not replayed", %{events: events} do
    # A notification already on disk when the tracker boots must not resurrect a
    # stale waiting state — the tail starts at end-of-file.
    append(events, "notification", "stale-01J-shuttle")
    name = start(events)

    Process.sleep(40)
    refute MapSet.member?(WaitingTracker.waiting_sessions(name), "stale-01J-shuttle")
  end

  test "file truncation resets the tail offset without crashing", %{events: events} do
    name = start(events)
    append(events, "notification", "foo-01J-shuttle")
    assert wait_until(fn -> MapSet.member?(WaitingTracker.waiting_sessions(name), "foo-01J-shuttle") end)

    # Rotate: truncate to empty (the real copytruncate shape — events.jsonl is
    # append-only-grow, so the poller observes size drop below its offset and
    # resets its read position). Let a poll cycle see the empty file before the
    # regrowth, then a fresh notification for a new session must still register.
    File.write!(events, "")
    Process.sleep(40)
    append(events, "notification", "bar-01J-shuttle")
    assert wait_until(fn -> MapSet.member?(WaitingTracker.waiting_sessions(name), "bar-01J-shuttle") end)
  end
end
