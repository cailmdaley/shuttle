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
