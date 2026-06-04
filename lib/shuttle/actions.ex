defmodule Shuttle.Actions do
  @moduledoc """
  Classifies Shuttle-owned lifecycle actions for external views.

  Portolan owns gestures and layout; Shuttle owns what those gestures mean for
  a fiber's dispatch lifecycle. This module is the small vocabulary bridge
  between the two.
  """

  @type action_id ::
          :pause
          | :reopen
          | :accept_run
          | :dispatch_ad_hoc
          | :close_awaiting_review
          | :close_tempered
          | :close_composted

  @transition_targets ~w(drafts inFlight queued active awaitingReview tempered composted)
  @action_ids ~w(pause reopen accept-run dispatch-ad-hoc close-awaiting-review close-tempered close-composted)

  @spec actions_for(map(), boolean()) :: [map()]
  def actions_for(fiber, running? \\ false) when is_map(fiber) do
    fiber
    |> action_ids(running?)
    |> Enum.map(&render_action/1)
  end

  @spec resolve_transition(map(), String.t(), boolean()) ::
          {:ok, map()} | {:error, :unknown_target}
  def resolve_transition(fiber, target, running? \\ false)

  def resolve_transition(fiber, target, running?) when target in @transition_targets do
    target = normalize_target(target)
    {:ok, render_action(action_for_target(fiber, target, running?))}
  end

  def resolve_transition(_fiber, _target, _running?), do: {:error, :unknown_target}

  @spec known_action?(String.t()) :: boolean()
  def known_action?(id), do: id in @action_ids

  # The normalized kanban drag targets, in column order. `action_ids/2`
  # derives the available-action set from `action_for_target/3` over exactly
  # this list, so the two functions can never disagree.
  @kanban_targets ~w(drafts inFlight awaitingReview tempered composted)

  # The available-action set is the distinct set of actions `action_for_target`
  # produces over every kanban drag target, plus `:pause` for a running worker
  # (which is always interruptible even when no column maps to pause in that
  # state — e.g. a closed-but-still-running fiber).
  #
  # Deriving the set *from* the resolver is the load-bearing invariant: for
  # every valid target t, `action_for_target(fiber, t, running?) ∈
  # action_ids(fiber, running?)` holds by construction, so a drag can never
  # 409 `action_not_available` from a resolve/availability disagreement. The
  # two cond-chains that used to be hand-maintained independently drifted
  # apart for 110 of the 270 (state × target) combinations; this collapses the
  # second chain into a projection of the first. Order is preserved
  # (`@kanban_targets` then `:pause`) so the rendered list is stable.
  #
  # See `gotcha-shuttle-resolve-invoke-daemon-split`.
  defp action_ids(fiber, running?) do
    derived =
      @kanban_targets
      |> Enum.map(&action_for_target(fiber, &1, running?))

    extras = if running?, do: [:pause], else: []

    (derived ++ extras) |> Enum.uniq()
  end

  defp action_for_target(fiber, target, running?) do
    shuttle = shuttle(fiber)
    status = Map.get(fiber, "status")

    cond do
      # A live worker: the close columns end it, drafts pauses it. inFlight is
      # the column it already lives in (a no-op same-column drop); resolve it to
      # `pause` so it stays a valid, non-destructive-on-its-own action that the
      # daemon already exposes for running workers — never a re-dispatch, which
      # the daemon would bounce as already_running.
      running? and target in ["drafts", "inFlight"] ->
        :pause

      running? and target == "awaitingReview" ->
        :close_awaiting_review

      running? and target == "tempered" ->
        :close_tempered

      running? and target == "composted" ->
        :close_composted

      # A closed fiber's only forward move is reopen (which clears closed_at /
      # tempered); shuttle-ctl refuses a direct pause/close on an already-closed
      # fiber. Portolan's un-temper sequence drags through inFlight first for
      # the other open-lifecycle targets, so every non-close target collapses to
      # reopen here. The close columns re-close with the chosen verdict.
      #
      # The verdict columns are split out from the open-lifecycle group (rather
      # than left to fall through to the standing-awaiting clauses below). A
      # CLOSED standing role can carry a stale `review.state: awaiting` in its
      # runtime store (close never reset it before the lifecycle-reset fix); if
      # `tempered`/`composted` fell through, c6/c7 would catch them — `tempered`
      # → accept-run, which re-arms a *closed* role's schedule (status forced
      # active, next_due_at in the future), silently dropping the user's
      # verdict. Resolving the verdict columns to their close verbs here keeps
      # the contract symmetric (tempered → close-tempered, composted →
      # close-composted) regardless of any leftover review state, and the
      # rendered set stays drag-safe by construction.
      status == "closed" and target in ["drafts", "inFlight", "awaitingReview"] ->
        :reopen

      status == "closed" and target == "tempered" ->
        :close_tempered

      status == "closed" and target == "composted" ->
        :close_composted

      # An awaiting standing role's pending run gets a human verdict: accept-run
      # keeps it (advance the schedule), close-composted drops it. inFlight ("run
      # it again now") is the same "keep it" gesture as tempered.
      standing?(shuttle) and review_state(shuttle) == "awaiting" and
          target in ["inFlight", "tempered"] ->
        :accept_run

      # `awaitingReview` is the awaiting role's HOME column — a drop there is a
      # same-column no-op (Portolan's drop handler already short-circuits
      # `fromColumn == target`, so this is only reached by a non-shipping caller
      # or a stale multi-step sequence). Resolve it to close-awaiting-review —
      # the non-verdict "this stays in review" verb — NOT close-composted, which
      # would silently destroy the pending run on what the user meant as a no-op.
      # close-awaiting-review joins `action_ids` by construction (it's the
      # resolution of a kanban target), so resolve ⊆ availability still holds.
      standing?(shuttle) and review_state(shuttle) == "awaiting" and
          target == "awaitingReview" ->
        :close_awaiting_review

      # drafts ("park it") on an awaiting role has no non-destructive verb in the
      # review vocabulary (pause isn't a review verb and would 409); compost the
      # pending run so the column stays available.
      standing?(shuttle) and review_state(shuttle) == "awaiting" and
          target in ["drafts", "composted"] ->
        :close_composted

      # A disabled fiber (paused draft) dragged out of drafts re-enables via
      # reopen; staying in drafts is a no-op pause. The close columns close it.
      not enabled?(shuttle) and target in ["drafts", "inFlight"] ->
        :reopen

      target == "drafts" ->
        :pause

      standing?(shuttle) and enabled?(shuttle) and target == "inFlight" and
          review_state(shuttle) in ["scheduled", "accepted"] ->
        :dispatch_ad_hoc

      # An enabled (non-standing) oneshot is already in the dispatch contract;
      # `inFlight` means "launch it now", not `reopen` (reopen only applies to a
      # closed or disabled fiber and is NOT in actions_for for an enabled one —
      # resolving to it here is what produced the 409 `action_not_available`
      # when a stranded-but-enabled oneshot was dragged from drafts to inFlight).
      # Force-dispatch instead, which surfaces the real dispatch outcome
      # (spawned, or a concrete error like missing host / project_dir).
      enabled?(shuttle) and not standing?(shuttle) and target == "inFlight" ->
        :dispatch_ad_hoc

      target == "inFlight" ->
        :reopen

      target == "awaitingReview" ->
        :close_awaiting_review

      target == "tempered" ->
        :close_tempered

      true ->
        :close_composted
    end
  end

  defp render_action(id) do
    %{id: Atom.to_string(id) |> String.replace("_", "-"), invocation: invocation(id)}
  end

  defp invocation(:pause), do: %{verb: "pause"}
  defp invocation(:reopen), do: %{verb: "reopen"}
  defp invocation(:accept_run), do: %{verb: "accept"}
  defp invocation(:dispatch_ad_hoc), do: %{verb: "dispatch", ad_hoc: true}
  defp invocation(:close_awaiting_review), do: %{verb: "close"}
  defp invocation(:close_tempered), do: %{verb: "close", tempered: true}
  defp invocation(:close_composted), do: %{verb: "close", tempered: false}

  defp normalize_target("queued"), do: "inFlight"
  defp normalize_target("active"), do: "inFlight"
  defp normalize_target(target), do: target

  # Total accessors: a malformed inline fiber (shuttle/review as a scalar or
  # list rather than a map) must degrade to the default path, not crash the
  # resolver with BadMapError / ArgumentError → a bare Phoenix 500. The current
  # client always builds well-formed shapes, so this is public-contract
  # robustness for any other caller. (overnight-audit C10 / finding 3.)
  defp shuttle(fiber) do
    case Map.get(fiber, "shuttle", %{}) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp enabled?(shuttle), do: Map.get(shuttle, "enabled") == true
  defp standing?(shuttle), do: Map.get(shuttle, "kind", Map.get(shuttle, "mode")) == "standing"

  defp review_state(shuttle) do
    case Map.get(shuttle, "review") do
      review when is_map(review) -> Map.get(review, "state") || "scheduled"
      _ -> "scheduled"
    end
  end
end
