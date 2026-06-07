defmodule Shuttle.StandingRoleTest do
  use ExUnit.Case, async: true

  alias Shuttle.StandingRole

  @now ~U[2026-06-02 10:00:00Z]

  # A schedule-due standing role (next_due_at in the past, scheduled review).
  defp role(overrides) do
    base = %{
      "kind" => "standing",
      "schedule" => %{"expr" => "0 9 * * 1-5", "tz" => "Europe/Paris"},
      "review" => %{"state" => "scheduled"},
      "next_due_at" => "2020-01-01T00:00:00Z"
    }

    {:ok, role} = StandingRole.from_map("f", Map.merge(base, overrides))
    role
  end

  describe "enabled gates the schedule-derived phases" do
    test "an armed, past-due role is due" do
      assert StandingRole.state(role(%{}), @now, false) == "due"
    end

    test "absent enabled defaults to armed" do
      assert role(%{}).enabled == true
      assert StandingRole.state(role(%{}), @now, false) == "due"
    end

    test "a paused role is dormant regardless of its schedule" do
      assert role(%{"enabled" => false}).enabled == false
      assert StandingRole.state(role(%{"enabled" => false}), @now, false) == "dormant"
    end

    test "a paused role with a preserved awaiting review is still dormant (pause is absolute → Drafts)" do
      paused_with_review =
        role(%{"enabled" => false, "review" => %{"state" => "awaiting"}, "next_due_at" => nil})

      assert StandingRole.state(paused_with_review, @now, false) == "dormant"
    end

    test "a live worker overrides dormant (a paused-with --no-kill role reads running until it ends)" do
      assert StandingRole.state(role(%{"enabled" => false}), @now, true) == "running"
    end
  end

  describe "due_by_cron? — the slice-2 dispatch gate, cron-computed and stateless" do
    @window_ms 90_000

    # An every-minute schedule always fires a tick inside any non-trivial window,
    # so it is the deterministic "due now" role independent of wall-clock.
    defp cron_role(expr, overrides \\ %{}) do
      base = %{
        "kind" => "standing",
        "schedule" => %{"expr" => expr, "tz" => "UTC"},
        "review" => %{"state" => "scheduled"}
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

    test "ignores review.state — the gate is cron + the doc, not review" do
      # A stale awaiting overlay does not change due-ness: the poller checks the
      # document's status/tempered, and this checks the cron window. `due?/2`
      # (the display path) still consults review.state and so differs here.
      now = ~U[2026-06-02 10:00:30Z]

      awaiting =
        cron_role("* * * * *", %{"review" => %{"state" => "awaiting", "run_id" => "adhoc-1"}})

      assert StandingRole.due_by_cron?(awaiting, now, @window_ms)
      refute StandingRole.due?(awaiting, now)
    end

    test "a missed tick (daemon down across it) is not replayed" do
      # The 10:00 tick fired five minutes before now; with a 90s window it is
      # outside the window and is skipped rather than replayed.
      now = ~U[2026-06-02 10:05:00Z]
      refute StandingRole.due_by_cron?(cron_role("0 10 * * *"), now, @window_ms)
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

  describe "dispatch_run_id — resume keeps the run id, fresh/accepted mints a new one" do
    @resume_now ~U[2026-06-05 16:04:19Z]

    test "a resumed run (preserved run_id, no accepted_run_id) keeps the awaiting run's id" do
      # LifecycleStore.resume leaves review = {state: scheduled, run_id: <preserved>}
      # and sets next_due_at = now. dispatch_run_id must return the preserved id,
      # NOT strftime(next_due_at) — otherwise the run window excludes the resume
      # directive and the dispatcher silently falls back to :fresh.
      resumed =
        role(%{
          "review" => %{"state" => "scheduled", "run_id" => "20260605T070000+0000"},
          "next_due_at" => "2026-06-05T16:04:19Z"
        })

      assert StandingRole.dispatch_run_id(resumed, @resume_now) == "20260605T070000+0000"
    end

    test "an accepted run (accepted_run_id == run_id) mints a fresh id from next_due_at" do
      # accept advances the recurrence; the next run is genuinely new, so the id
      # comes from next_due_at (the next cron occurrence), not the accepted run.
      accepted =
        role(%{
          "review" => %{
            "state" => "scheduled",
            "run_id" => "20260605T070000+0000",
            "accepted_run_id" => "20260605T070000+0000"
          },
          "next_due_at" => "2026-06-08T09:00:00+02:00"
        })

      assert StandingRole.dispatch_run_id(accepted, @resume_now) ==
               StandingRole.next_run_id(accepted, @resume_now)

      refute StandingRole.dispatch_run_id(accepted, @resume_now) == "20260605T070000+0000"
    end

    test "a fresh scheduled role (no run_id) mints from next_due_at" do
      fresh = role(%{"review" => %{"state" => "scheduled"}, "next_due_at" => "2026-06-08T09:00:00+02:00"})

      assert StandingRole.dispatch_run_id(fresh, @resume_now) ==
               StandingRole.next_run_id(fresh, @resume_now)
    end
  end
end
