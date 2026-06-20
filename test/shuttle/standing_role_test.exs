defmodule Shuttle.StandingRoleTest do
  use ExUnit.Case, async: true

  alias Shuttle.StandingRole

  @now ~U[2026-06-02 10:00:00Z]

  # A standing role. Due-ness is computed from the cron schedule + now (slice 4:
  # no stored next_due_at, no review block). `* * * * *` fires every minute, so a
  # tick is always at/before now → the deterministic "due" role; the daily
  # weekday 09:00 schedule's next tick at 10:00 Tue is tomorrow → "scheduled".
  defp role(overrides) do
    base = %{
      "kind" => "standing",
      "schedule" => %{"expr" => "* * * * *", "tz" => "Europe/Paris"}
    }

    {:ok, role} = StandingRole.from_map("f", Map.merge(base, overrides))
    role
  end

  # The schedule-derived display phase is now cron + liveness only (slice 5: no
  # enabled axis). Paused/draft is a document fact (`status: open`) surfaced by
  # the kanban classifier, not a StandingRole phase — `state/3` answers only the
  # schedule question for an armed role.
  describe "schedule-derived phase (cron + liveness)" do
    test "an armed role whose tick has arrived is due" do
      assert StandingRole.state(role(%{}), @now, false) == "due"
    end

    test "an armed role whose next tick is in the future is scheduled, not due" do
      sleeping = role(%{"schedule" => %{"expr" => "0 9 * * 1-5", "tz" => "UTC"}})
      assert StandingRole.state(sleeping, @now, false) == "scheduled"
    end

    test "a live worker reads running regardless of schedule" do
      assert StandingRole.state(role(%{}), @now, true) == "running"
    end
  end

  describe "due_by_cron? — the slice-2 dispatch gate, cron-computed and stateless" do
    @window_ms 90_000

    # An every-minute schedule always fires a tick inside any non-trivial window,
    # so it is the deterministic "due now" role independent of wall-clock.
    defp cron_role(expr, overrides \\ %{}) do
      base = %{
        "kind" => "standing",
        "schedule" => %{"expr" => expr, "tz" => "UTC"}
      }

      {:ok, role} = StandingRole.from_map("f", Map.merge(base, overrides))
      role
    end

    test "a role whose tick fired inside the window is due" do
      now = ~U[2026-06-02 10:00:30Z]
      # `* * * * *` fires every minute → a tick at 10:00:00 sits in the window.
      assert StandingRole.due_by_cron?(cron_role("* * * * *"), now, @window_ms)
    end

    test "a role whose next tick is in the future (no tick in window) is not due" do
      # The window opens at 09:58:30 and closes at 10:00:00; the daily 09:00 tick
      # already fell before the window, and the next is tomorrow 09:00 — neither
      # is inside the window, so the role is not due (missed ticks are skipped).
      now = ~U[2026-06-02 10:00:00Z]
      refute StandingRole.due_by_cron?(cron_role("0 9 * * *"), now, @window_ms)
    end

    test "due-ness is cron + the doc, never a review axis" do
      # The dispatch gate is purely the cron window (and the poller's document
      # status/tempered check before it). There is no review.state to consult —
      # a leftover review key in the block has no effect on due-ness (slice 4).
      now = ~U[2026-06-02 10:00:30Z]

      with_stray_review =
        cron_role("* * * * *", %{"review" => %{"state" => "awaiting", "run_id" => "adhoc-1"}})

      assert StandingRole.due_by_cron?(with_stray_review, now, @window_ms)
    end

    test "a tick outside the lookback is not served (already handled / serviced since)" do
      # The 10:00 tick fired five minutes before now; with a 90s lookback it is
      # outside the window and not served. In the live system the lookback is
      # `now - last_service`, so this is the shape of "we ran after this tick" —
      # the per-cycle gate that stops a handled tick from re-firing.
      now = ~U[2026-06-02 10:05:00Z]
      refute StandingRole.due_by_cron?(cron_role("0 10 * * *"), now, @window_ms)
    end

    test "a missed tick IS replayed when the lookback reaches it (catch-up)" do
      # The live system anchors the lookback at the role's last service, so a tick
      # the daemon slept through is caught however late. The 10:00 tick fired five
      # minutes ago; a lookback that spans the last service (6 min) makes it due —
      # the catch-up that fires a Friday-08:00 chase when the laptop wakes later.
      now = ~U[2026-06-02 10:05:00Z]
      assert StandingRole.due_by_cron?(cron_role("0 10 * * *"), now, 6 * 60 * 1000)
    end

    test "an invalid role is never due" do
      # mode must be standing; a oneshot block fails validation.
      now = ~U[2026-06-02 10:00:30Z]
      refute StandingRole.due_by_cron?(cron_role("* * * * *", %{"kind" => "oneshot"}), now, @window_ms)
    end

    test "a role with an unparseable schedule is not due" do
      now = ~U[2026-06-02 10:00:30Z]
      refute StandingRole.due_by_cron?(cron_role("not a cron"), now, @window_ms)
    end
  end

  describe "next_due_from_cron — display next_due is cron.next(now)" do
    test "returns the next scheduled occurrence after now" do
      now = ~U[2026-06-02 10:00:00Z]
      role = role(%{"schedule" => %{"expr" => "0 9 * * 1-5", "tz" => "UTC"}})
      # Next weekday 09:00 UTC after 2026-06-02 10:00 is 2026-06-03 09:00.
      assert %DateTime{} = next = StandingRole.next_due_from_cron(role, now)
      assert DateTime.compare(next, ~U[2026-06-03 09:00:00Z]) == :eq
    end

    test "returns nil for an unparseable schedule" do
      now = ~U[2026-06-02 10:00:00Z]
      role = role(%{"schedule" => %{"expr" => "garbage", "tz" => "UTC"}})
      assert StandingRole.next_due_from_cron(role, now) == nil
    end
  end

  describe "dispatch_run_id — a fresh display label every dispatch (slice 4)" do
    @resume_now ~U[2026-06-05 16:04:19Z]

    test "mints from now — the id is no longer load-bearing for resume continuity" do
      # Continuation is decided from the per-host dispatch/handoff markers, not
      # parsed from this id. The id is therefore a fresh timestamp label every
      # dispatch, regardless of any leftover review block.
      role = role(%{})

      assert StandingRole.dispatch_run_id(role, @resume_now) ==
               StandingRole.next_run_id(role, @resume_now)
    end

    test "a stray review.run_id in the block does not pin the id" do
      with_stray_review =
        role(%{"review" => %{"state" => "scheduled", "run_id" => "20260605T070000+0000"}})

      refute StandingRole.dispatch_run_id(with_stray_review, @resume_now) == "20260605T070000+0000"

      assert StandingRole.dispatch_run_id(with_stray_review, @resume_now) ==
               StandingRole.next_run_id(with_stray_review, @resume_now)
    end
  end
end
