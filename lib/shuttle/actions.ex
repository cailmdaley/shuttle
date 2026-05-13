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
          | :continue_run_fresh
          | :continue_run_previous
          | :dispatch_ad_hoc
          | :close_awaiting_review
          | :close_tempered
          | :close_composted

  @transition_targets ~w(drafts inFlight queued active awaitingReview tempered composted)
  @action_ids ~w(pause reopen accept-run continue-run-fresh continue-run-previous dispatch-ad-hoc close-awaiting-review close-tempered close-composted)

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

  defp action_ids(fiber, running?) do
    shuttle = shuttle(fiber)
    status = Map.get(fiber, "status")

    cond do
      running? ->
        [:pause, :close_awaiting_review, :close_tempered, :close_composted]

      status == "closed" ->
        [:reopen, :close_tempered, :close_composted]

      standing?(shuttle) and review_state(shuttle) == "awaiting" ->
        [:accept_run, :continue_run_fresh] ++
          maybe_continue_previous(shuttle) ++ [:close_composted]

      standing?(shuttle) and enabled?(shuttle) ->
        [:pause, :dispatch_ad_hoc]

      standing?(shuttle) ->
        [:reopen]

      enabled?(shuttle) ->
        [:pause, :close_awaiting_review, :close_tempered, :close_composted]

      true ->
        [:reopen]
    end
  end

  defp maybe_continue_previous(shuttle) do
    case get_in(shuttle, ["session", "id"]) do
      id when is_binary(id) and id != "" -> [:continue_run_previous]
      _ -> []
    end
  end

  defp action_for_target(fiber, target, _running?) do
    shuttle = shuttle(fiber)
    status = Map.get(fiber, "status")

    cond do
      status == "closed" and target == "inFlight" ->
        :reopen

      standing?(shuttle) and review_state(shuttle) == "awaiting" and
          target in ["inFlight", "tempered"] ->
        :accept_run

      target == "drafts" ->
        :pause

      standing?(shuttle) and enabled?(shuttle) and target == "inFlight" and
          review_state(shuttle) in ["scheduled", "accepted"] ->
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
  defp invocation(:continue_run_fresh), do: %{verb: "resume", resume_mode: "fresh"}
  defp invocation(:continue_run_previous), do: %{verb: "resume", resume_mode: "previous"}
  defp invocation(:dispatch_ad_hoc), do: %{verb: "dispatch", ad_hoc: true}
  defp invocation(:close_awaiting_review), do: %{verb: "close"}
  defp invocation(:close_tempered), do: %{verb: "close", tempered: true}
  defp invocation(:close_composted), do: %{verb: "close", tempered: false}

  defp normalize_target("queued"), do: "inFlight"
  defp normalize_target("active"), do: "inFlight"
  defp normalize_target(target), do: target

  defp shuttle(fiber), do: Map.get(fiber, "shuttle", %{}) || %{}
  defp enabled?(shuttle), do: Map.get(shuttle, "enabled") == true
  defp standing?(shuttle), do: Map.get(shuttle, "kind", Map.get(shuttle, "mode")) == "standing"
  defp review_state(shuttle), do: get_in(shuttle, ["review", "state"]) || "scheduled"
end
