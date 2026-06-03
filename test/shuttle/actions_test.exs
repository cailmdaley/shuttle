defmodule Shuttle.ActionsTest do
  use ExUnit.Case, async: true

  alias Shuttle.Actions

  test "awaiting standing-role transitions resolve to accept-run" do
    fiber = standing("awaiting")

    assert {:ok, %{id: "accept-run", invocation: %{verb: "accept"}}} =
             Actions.resolve_transition(fiber, "tempered")

    assert {:ok, %{id: "accept-run", invocation: %{verb: "accept"}}} =
             Actions.resolve_transition(fiber, "inFlight")
  end

  test "dormant standing-role in-flight transition resolves to ad-hoc dispatch" do
    fiber = standing("scheduled")

    assert {:ok, %{id: "dispatch-ad-hoc", invocation: %{verb: "dispatch", ad_hoc: true}}} =
             Actions.resolve_transition(fiber, "inFlight")
  end

  test "closed standing-role must reopen before dispatching" do
    fiber = %{standing("scheduled") | "status" => "closed"}

    actions = Actions.actions_for(fiber)
    assert Enum.any?(actions, &(&1.id == "reopen"))
    refute Enum.any?(actions, &(&1.id == "dispatch-ad-hoc"))

    assert {:ok, %{id: "reopen", invocation: %{verb: "reopen"}}} =
             Actions.resolve_transition(fiber, "inFlight")
  end

  test "oneshot transition vocabulary stays lifecycle-shaped" do
    fiber = %{
      "id" => "work/thing",
      "status" => "closed",
      "shuttle" => %{"enabled" => true, "kind" => "oneshot"}
    }

    assert {:ok, %{id: "close-tempered", invocation: %{verb: "close", tempered: true}}} =
             Actions.resolve_transition(fiber, "tempered")
  end

  test "paused oneshot drafts can be closed directly into review or verdicts" do
    fiber = %{
      "id" => "work/draft",
      "status" => "open",
      "shuttle" => %{"enabled" => false, "kind" => "oneshot"}
    }

    actions = Actions.actions_for(fiber)
    assert Enum.any?(actions, &(&1.id == "reopen"))
    assert Enum.any?(actions, &(&1.id == "close-awaiting-review"))
    assert Enum.any?(actions, &(&1.id == "close-tempered"))
    assert Enum.any?(actions, &(&1.id == "close-composted"))

    assert {:ok, %{id: "close-tempered", invocation: %{verb: "close", tempered: true}}} =
             Actions.resolve_transition(fiber, "tempered")
  end

  test "running oneshots can still be closed into review or verdict columns" do
    fiber = %{
      "id" => "work/running",
      "status" => "active",
      "shuttle" => %{"enabled" => true, "kind" => "oneshot"}
    }

    actions = Actions.actions_for(fiber, true)
    assert Enum.any?(actions, &(&1.id == "pause"))
    assert Enum.any?(actions, &(&1.id == "close-awaiting-review"))
    assert Enum.any?(actions, &(&1.id == "close-tempered"))
    assert Enum.any?(actions, &(&1.id == "close-composted"))
    refute Enum.any?(actions, &(&1.id == "reopen"))
  end

  test "awaiting standing-role offers accept or compost, not a continue verb" do
    fiber = standing("awaiting")
    actions = Actions.actions_for(fiber)

    assert Enum.any?(actions, &(&1.id == "accept-run"))
    assert Enum.any?(actions, &(&1.id == "close-composted"))
    refute Enum.any?(actions, &(&1.id == "continue-run-fresh"))
    refute Enum.any?(actions, &(&1.id == "continue-run-previous"))
  end

  defp standing(review_state) do
    %{
      "id" => "work/standing",
      "status" => "active",
      "shuttle" => %{
        "enabled" => true,
        "kind" => "standing",
        "review" => %{"state" => review_state}
      }
    }
  end
end
