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

  test "closed + untempered standing role is awaiting: re-arm or compost, not reopen" do
    # New-model awaiting: `status: closed` + no `tempered` on a standing role.
    # The verdict gestures re-arm (accept-run) or reject (close-composted); this
    # closed role does NOT collapse to reopen the way a oneshot does.
    fiber = %{standing("scheduled") | "status" => "closed"}

    assert {:ok, %{id: "accept-run", invocation: %{verb: "accept"}}} =
             Actions.resolve_transition(fiber, "inFlight")

    assert {:ok, %{id: "accept-run", invocation: %{verb: "accept"}}} =
             Actions.resolve_transition(fiber, "tempered")

    assert {:ok, %{id: "close-composted", invocation: %{verb: "close", tempered: false}}} =
             Actions.resolve_transition(fiber, "composted")

    assert {:ok, %{id: "close-composted"}} = Actions.resolve_transition(fiber, "drafts")

    assert {:ok, %{id: "close-awaiting-review"}} =
             Actions.resolve_transition(fiber, "awaitingReview")

    # Every resolved action is in the available set (drag-safety invariant).
    actions = Actions.actions_for(fiber)
    assert Enum.any?(actions, &(&1.id == "accept-run"))
    refute Enum.any?(actions, &(&1.id == "reopen"))
  end

  test "closed + composted standing role (tempered:false) is a terminus, reopen to revive" do
    # A rejected standing role carries a verdict (`tempered: false`), so it is
    # NOT awaiting — it falls through to the generic closed clauses: reopen to
    # revive, close columns re-close with a verdict.
    fiber = Map.merge(standing("scheduled"), %{"status" => "closed", "tempered" => false})

    assert {:ok, %{id: "reopen", invocation: %{verb: "reopen"}}} =
             Actions.resolve_transition(fiber, "inFlight")

    assert {:ok, %{id: "close-tempered", invocation: %{verb: "close", tempered: true}}} =
             Actions.resolve_transition(fiber, "tempered")
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

  test "enabled idle oneshot dragged to inFlight force-dispatches (not reopen)" do
    # Regression for the 409 `action_not_available` bug: an enabled oneshot
    # with no live worker classifies into the drafts fallback, so dragging it
    # to inFlight resolved to `reopen` — which is NOT in actions_for for an
    # enabled fiber, so the invoke step (validate_available) rejected it. The
    # resolve and availability cond-chains disagreed. The fix: inFlight on an
    # enabled oneshot means "launch it now" → dispatch-ad-hoc, which IS made
    # available below. This test pins the invariant: every resolved action
    # must be present in actions_for.
    fiber = %{
      "id" => "work/idle-enabled",
      "status" => "active",
      "shuttle" => %{"enabled" => true, "kind" => "oneshot"}
    }

    actions = Actions.actions_for(fiber)
    assert Enum.any?(actions, &(&1.id == "dispatch-ad-hoc"))
    assert Enum.any?(actions, &(&1.id == "pause"))
    refute Enum.any?(actions, &(&1.id == "reopen"))

    assert {:ok, %{id: resolved}} = Actions.resolve_transition(fiber, "inFlight")
    assert resolved == "dispatch-ad-hoc"
    # The invariant the bug violated: the resolved action is available.
    assert Enum.any?(actions, &(&1.id == resolved))
  end

  test "disabled oneshot draft dragged to inFlight still reopens (enables it)" do
    # The disabled path is unchanged: reopen is the verb that flips a paused
    # draft back to enabled, and it remains in actions_for for disabled fibers.
    fiber = %{
      "id" => "work/paused-draft",
      "status" => "open",
      "shuttle" => %{"enabled" => false, "kind" => "oneshot"}
    }

    actions = Actions.actions_for(fiber)
    assert Enum.any?(actions, &(&1.id == "reopen"))
    refute Enum.any?(actions, &(&1.id == "dispatch-ad-hoc"))

    assert {:ok, %{id: "reopen", invocation: %{verb: "reopen"}}} =
             Actions.resolve_transition(fiber, "inFlight")
  end

  test "awaiting standing-role offers accept or compost, not a continue verb" do
    fiber = standing("awaiting")
    actions = Actions.actions_for(fiber)

    assert Enum.any?(actions, &(&1.id == "accept-run"))
    assert Enum.any?(actions, &(&1.id == "close-composted"))
    refute Enum.any?(actions, &(&1.id == "continue-run-fresh"))
    refute Enum.any?(actions, &(&1.id == "continue-run-previous"))
  end

  describe "resolve/availability invariant (the whole 409 class)" do
    # The load-bearing property: for every (state × kanban target) combination,
    # the action `resolve_transition` picks for a drag MUST be present in the
    # `actions_for` availability set. When it isn't, the daemon's
    # `validate_available` rejects the invoke with 409 `action_not_available`.
    #
    # Before the by-construction fix (action_ids derived from action_for_target),
    # the two cond-chains were hand-maintained independently and disagreed for
    # 110 of these 270 combinations. This test sweeps the full matrix so any
    # future edit that reintroduces a disagreement fails here, loudly, with the
    # exact offending combination — not silently in a live drag.
    @kanban_targets ~w(drafts inFlight awaitingReview tempered composted)
    @statuses ~w(open active closed)
    @kinds ~w(oneshot standing)
    @review_states ~w(scheduled awaiting accepted)

    test "every resolved drag target is an available action across the full matrix" do
      combos =
        for status <- @statuses,
            enabled <- [true, false],
            kind <- @kinds,
            review <- @review_states,
            running? <- [false, true],
            target <- @kanban_targets do
          fiber = %{
            "id" => "work/matrix",
            "status" => status,
            "shuttle" => %{
              "enabled" => enabled,
              "kind" => kind,
              "review" => %{"state" => review}
            }
          }

          available = Actions.actions_for(fiber, running?) |> Enum.map(& &1.id)
          {:ok, %{id: resolved}} = Actions.resolve_transition(fiber, target, running?)

          {%{
             status: status,
             enabled: enabled,
             kind: kind,
             review: review,
             running: running?,
             target: target,
             resolved: resolved,
             available: available
           }, resolved in available}
        end

      violations =
        combos
        |> Enum.reject(fn {_combo, ok?} -> ok? end)
        |> Enum.map(fn {combo, _} -> combo end)

      assert violations == [],
             "resolve/availability disagreement for #{length(violations)} combos:\n" <>
               Enum.map_join(violations, "\n", fn v ->
                 "  status=#{v.status} enabled=#{v.enabled} kind=#{v.kind} " <>
                   "review=#{v.review} running=#{v.running} target=#{v.target} " <>
                   "→ resolved=#{v.resolved} NOT IN #{inspect(v.available)}"
               end)
    end

    test "a CLOSED standing role WITH A VERDICT (tempered set) resolves to close/reopen, never accept-run" do
      # The verdict-protection invariant in new-model terms. Awaiting is now
      # `status: closed` + tempered UNSET; the moment a verdict lands (`tempered`
      # present, true or false) the role is a terminus, not awaiting, so the
      # awaiting re-arm clauses must NOT fire. This pins the entanglement guard:
      # accept-run is reserved for genuinely-awaiting (untempered) closed roles;
      # a role the user already ruled on falls through to the generic closed
      # clauses (reopen to revive, close columns re-close with a verdict). A
      # stale `review.state: awaiting` in frontmatter must not override the
      # verdict — `tempered` presence wins.
      fiber = %{
        "id" => "work/closed-verdict",
        "status" => "closed",
        "tempered" => false,
        "shuttle" => %{"enabled" => true, "kind" => "standing", "review" => %{"state" => "awaiting"}}
      }

      assert {:ok, %{id: "close-tempered", invocation: %{verb: "close", tempered: true}}} =
               Actions.resolve_transition(fiber, "tempered")

      assert {:ok, %{id: "close-composted", invocation: %{verb: "close", tempered: false}}} =
               Actions.resolve_transition(fiber, "composted")

      # The open-lifecycle columns still reopen (clears closed_at / tempered);
      # accept-run must NOT appear for a closed role that already has a verdict.
      for target <- ~w(drafts inFlight awaitingReview) do
        assert {:ok, %{id: "reopen"}} = Actions.resolve_transition(fiber, target)
      end

      available = Actions.actions_for(fiber) |> Enum.map(& &1.id)
      refute "accept-run" in available
    end

    test "same-column awaitingReview drop on a live awaiting standing role is non-destructive" do
      # The awaiting role's HOME column is awaitingReview. A drop there is a
      # same-column no-op; it must not silently compost the pending run. Resolves
      # to close-awaiting-review (the non-verdict "stays in review" verb), never
      # close-composted. Pins the legit verdict columns at the same time:
      # tempered/inFlight = accept (keep the run), composted = compost (drop it).
      fiber = standing("awaiting")

      assert {:ok, %{id: "close-awaiting-review", invocation: %{verb: "close"}}} =
               Actions.resolve_transition(fiber, "awaitingReview")

      assert {:ok, %{id: "accept-run"}} = Actions.resolve_transition(fiber, "tempered")
      assert {:ok, %{id: "accept-run"}} = Actions.resolve_transition(fiber, "inFlight")
      assert {:ok, %{id: "close-composted"}} = Actions.resolve_transition(fiber, "composted")
    end

    test "a disabled standing role can still be composted (the canary repro)" do
      # ai-futures/shuttle/misc/standing-roles/canary-local-snapshot: a disabled
      # standing role used to expose `[:reopen]` only, so dragging it to any
      # close column 409'd. It must now offer the full close vocabulary.
      fiber = %{
        "id" => "work/disabled-standing",
        "status" => "active",
        "shuttle" => %{"enabled" => false, "kind" => "standing", "review" => %{"state" => "scheduled"}}
      }

      actions = Actions.actions_for(fiber) |> Enum.map(& &1.id)
      assert "reopen" in actions
      assert "close-composted" in actions
      assert "close-tempered" in actions

      assert {:ok, %{id: "close-composted"}} = Actions.resolve_transition(fiber, "composted")
      assert {:ok, %{id: "close-tempered"}} = Actions.resolve_transition(fiber, "tempered")
    end
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
