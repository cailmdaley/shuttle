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
end
