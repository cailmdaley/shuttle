defmodule Shuttle.WaitingTrackerTest do
  use ExUnit.Case, async: false

  alias Shuttle.WaitingTracker

  @gate_ms 60_000
  # Events are ingested against this fixed clock, so a `:stopped` entry's `since`
  # is always exactly @base. Reads pass an explicit `now` to `waiting_phases/2`,
  # decoupling the read clock from ingestion — the gate becomes a pure function
  # of stored state and the supplied `now`, with no race against the async poll.
  @base 1_000_000

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
      WaitingTracker.start_link(
        events_file: events,
        poll_interval_ms: 10,
        clock: fn -> @base end,
        name: name
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  defp append(events, type, session) do
    line = Jason.encode!(%{type: type, tmuxSession: session})
    File.write!(events, line <> "\n", [:append])
  end

  # Phase at an explicit read-time clock (defaults to ingestion-time @base).
  defp phase(name, session, now \\ @base),
    do: Map.get(WaitingTracker.waiting_phases(name, now), session)

  # Whether a session has any tracked entry at all, regardless of the read-time
  # gate — reads far past the gate so a `:stopped` entry surfaces as "waiting".
  defp ingested?(name, session), do: not is_nil(phase(name, session, @base + 10 * @gate_ms))

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries <= 0 -> false
      true -> Process.sleep(10); wait_until(fun, tries - 1)
    end
  end

  test "a stop event yields \"waiting\" only after the 60s gate matures",
       %{events: events} do
    name = start(events)
    append(events, "stop", "foo-01J-shuttle")

    # Before the gate matures the session is omitted entirely (treated as busy).
    assert wait_until(fn -> ingested?(name, "foo-01J-shuttle") end)
    refute phase(name, "foo-01J-shuttle")

    # Read past the gate — flips to "waiting" with no new event, purely by elapsed time.
    assert phase(name, "foo-01J-shuttle", @base + @gate_ms) == "waiting"
  end

  test "a stop event before the gate is not reported", %{events: events} do
    name = start(events)
    append(events, "stop", "foo-01J-shuttle")

    assert wait_until(fn -> ingested?(name, "foo-01J-shuttle") end)
    # Just shy of the gate — still omitted.
    refute phase(name, "foo-01J-shuttle", @base + @gate_ms - 1)
  end

  test "a notification event yields \"attention\" immediately, no gate",
       %{events: events} do
    name = start(events)
    append(events, "notification", "foo-01J-shuttle")

    assert wait_until(fn -> phase(name, "foo-01J-shuttle") == "attention" end)
  end

  test "attention is sticky over a later stop — never downgrades to waiting",
       %{events: events} do
    name = start(events)
    append(events, "notification", "foo-01J-shuttle")
    assert wait_until(fn -> phase(name, "foo-01J-shuttle") == "attention" end)

    append(events, "stop", "foo-01J-shuttle")
    # Give the stop a chance to be ingested; even reading well past the gate must
    # not turn attention into waiting.
    Process.sleep(40)
    assert phase(name, "foo-01J-shuttle", @base + 10 * @gate_ms) == "attention"
  end

  test "a notification upgrades a prior stopped to attention", %{events: events} do
    name = start(events)
    append(events, "stop", "foo-01J-shuttle")
    assert wait_until(fn -> ingested?(name, "foo-01J-shuttle") end)

    append(events, "notification", "foo-01J-shuttle")
    assert wait_until(fn -> phase(name, "foo-01J-shuttle") == "attention" end)
  end

  for activity <- ["post_tool_use", "user_prompt_submit", "session_end"] do
    test "an activity event (#{activity}) clears the state", %{events: events} do
      name = start(events)
      append(events, "notification", "foo-01J-shuttle")
      assert wait_until(fn -> phase(name, "foo-01J-shuttle") == "attention" end)

      append(events, unquote(activity), "foo-01J-shuttle")
      assert wait_until(fn -> not ingested?(name, "foo-01J-shuttle") end)
    end
  end

  test "subagent_stop CLEARS — it does not mark waiting", %{events: events} do
    name = start(events)
    # First mark stopped so there is something to clear...
    append(events, "stop", "foo-01J-shuttle")
    assert wait_until(fn -> ingested?(name, "foo-01J-shuttle") end)

    # ...a subagent finishing means the main agent is mid-orchestration (busy):
    # it clears, and never appears even when read well past the gate.
    append(events, "subagent_stop", "foo-01J-shuttle")
    assert wait_until(fn -> not ingested?(name, "foo-01J-shuttle") end)
    refute phase(name, "foo-01J-shuttle", @base + 2 * @gate_ms)
  end

  test "non-shuttle sessions are ignored", %{events: events} do
    name = start(events)
    append(events, "notification", "my-interactive-session")
    # Give the tailer a couple of cycles to ingest.
    Process.sleep(40)
    refute phase(name, "my-interactive-session")
  end

  test "historical events before boot are not replayed", %{events: events} do
    # A notification already on disk when the tracker boots must not resurrect a
    # stale state — the tail starts at end-of-file.
    append(events, "notification", "stale-01J-shuttle")
    name = start(events)

    Process.sleep(40)
    refute phase(name, "stale-01J-shuttle")
  end

  test "a partial line (no trailing newline yet) is not consumed until complete",
       %{events: events} do
    name = start(events)

    # Write a notification record WITHOUT its trailing newline — a record still
    # mid-write. It must not be parsed-and-dropped; the session stays unseen.
    line = Jason.encode!(%{type: "notification", tmuxSession: "foo-01J-shuttle"})
    File.write!(events, line, [:append])
    Process.sleep(40)
    refute phase(name, "foo-01J-shuttle")

    # Complete the line — now it registers as attention.
    File.write!(events, "\n", [:append])
    assert wait_until(fn -> phase(name, "foo-01J-shuttle") == "attention" end)
  end

  test "file truncation resets the tail offset without crashing",
       %{events: events} do
    name = start(events)
    append(events, "notification", "foo-01J-shuttle")
    assert wait_until(fn -> phase(name, "foo-01J-shuttle") == "attention" end)

    # Rotate: truncate to empty (the real copytruncate shape — events.jsonl is
    # append-only-grow, so the poller observes size drop below its offset and
    # resets its read position). Let a poll cycle see the empty file before the
    # regrowth, then a fresh notification for a new session must still register.
    File.write!(events, "")
    Process.sleep(40)
    append(events, "notification", "bar-01J-shuttle")
    assert wait_until(fn -> phase(name, "bar-01J-shuttle") == "attention" end)
  end

end
