defmodule Shuttle.StandingRole do
  @moduledoc """
  Parses and classifies `shuttle.mode: standing` fiber declarations.

  Standing roles are still felt fibers. Shuttle only interprets the `shuttle:`
  frontmatter block to decide whether a role is sleeping, due, running, or in
  review.
  """

  defstruct [
    :fiber_id,
    :mode,
    :schedule,
    :review,
    :next_due_at,
    :last_run_at,
    :run_id,
    enabled: true,
    validation_errors: []
  ]

  @canonical_review_states ~w(scheduled awaiting accepted)
  @awaiting_review_states ~w(awaiting review in_review)
  @scheduleable_review_states ~w(scheduled accepted)
  @legacy_review_states ~w(review in_review)

  @type t :: %__MODULE__{
          fiber_id: String.t(),
          mode: String.t() | nil,
          schedule: map(),
          review: map(),
          next_due_at: DateTime.t() | nil,
          last_run_at: DateTime.t() | nil,
          run_id: String.t() | nil,
          enabled: boolean(),
          validation_errors: [String.t()]
        }

  @spec from_map(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def from_map(fiber_id, data) when is_map(data) do
    role = %__MODULE__{
      fiber_id: fiber_id,
      mode: string(data["kind"] || data["mode"]),
      schedule: map(data["schedule"]),
      review: map(data["review"]),
      next_due_at: parse_datetime(data["next_due_at"]),
      last_run_at: parse_datetime(data["last_run_at"]),
      run_id: string(get_in(data, ["review", "run_id"])),
      # `enabled` gates the schedule-derived phases. Absent or true ⇒ armed;
      # only an explicit `false` (a pause) makes the role dormant. See state/3.
      enabled: Map.get(data, "enabled") != false
    }

    {:ok, %{role | validation_errors: validation_errors(role)}}
  end

  @spec standing?(t() | nil) :: boolean()
  def standing?(%__MODULE__{mode: "standing"}), do: true
  def standing?(_), do: false

  @spec state(t(), DateTime.t(), boolean()) :: String.t()
  def state(%__MODULE__{} = role, now, running?) do
    review_state = role.review["state"] || "scheduled"

    cond do
      # A live worker is a fact, not a schedule conclusion — it wins even for a
      # role paused with `--no-kill`, so the card reads true until the run ends.
      running? -> "running"
      # Paused (`enabled: false`) collapses every schedule-derived phase to
      # dormant → the kanban reads Drafts. A preserved `review` survives in the
      # facts (accept/temper re-enables and reschedules); it just doesn't keep
      # the card out of Drafts. The dispatch gate (poller `eligible?`) already
      # honored `enabled`; this aligns the *display* with it.
      not role.enabled -> "dormant"
      review_state in @awaiting_review_states -> "review"
      review_state == "accepted" -> "accepted"
      due?(role, now) -> "due"
      true -> "scheduled"
    end
  end

  @spec due?(t(), DateTime.t()) :: boolean()
  def due?(
        %__MODULE__{next_due_at: %DateTime{} = next_due_at, review: review} = role,
        %DateTime{} = now
      ) do
    valid?(role) and (review["state"] || "scheduled") in @scheduleable_review_states and
      DateTime.compare(next_due_at, now) != :gt
  end

  def due?(_, _), do: false

  @doc """
  Cron-derived due check for the **dispatch** path: a valid role whose schedule
  fired a tick inside the window `(now - window_ms, now]`.

  This is the slice-2 cutover: due-ness is computed straight from the cron
  `schedule` and `now`, NOT from a stored `next_due_at`. The window anchors on
  `now` and is the poll interval (plus jitter slack), so a tick is caught by the
  first poll after it fires and **missed ticks are skipped, not replayed** — a
  tick that fell before the window (daemon down across it) is gone, exactly the
  morning-post-drift rule. Once a role fires, its document flips
  `active → closed`, and `eligible?` excludes closed, so it cannot re-fire within
  the same cycle even though the cron tick stays inside the window for a poll or
  two; the `active → closed → active` document transition is the per-cycle gate,
  not a stored timestamp.

  It does NOT consult `review.state` — the dispatch gate is the felt document's
  `status`/`tempered` (the poller checks those before calling this). `due?/2`
  keeps the review gate for the kanban **display** path (`state/3`) until the
  overlay is deleted in slice 4.
  """
  @spec due_by_cron?(t(), DateTime.t(), pos_integer()) :: boolean()
  def due_by_cron?(%__MODULE__{schedule: schedule} = role, %DateTime{} = now, window_ms)
      when is_integer(window_ms) and window_ms > 0 do
    window_start = DateTime.add(now, -window_ms, :millisecond)

    dispatchable?(role) and
      match?(
        {:ok, %DateTime{}},
        with {:ok, tick} <- Shuttle.Cron.next_occurrence(schedule, window_start),
             true <- DateTime.compare(tick, now) != :gt do
          {:ok, tick}
        else
          _ -> :no_tick
        end
      )
  end

  def due_by_cron?(_, _, _), do: false

  # Dispatch-path validity: a standing role with a parseable schedule. Slice 2
  # deliberately does NOT gate dispatch on `valid?/1`, which still carries the
  # legacy "scheduleable review state requires next_due_at" coupling — the live
  # daily-practice role has no stored next_due_at and no review block, yet must
  # dispatch off its cron. Those review/next_due validations only constrain the
  # display path until the overlay is deleted in slice 4.
  defp dispatchable?(%__MODULE__{mode: "standing", schedule: schedule}) do
    match?({:ok, %DateTime{}}, Shuttle.Cron.next_occurrence(schedule, DateTime.utc_now()))
  end

  defp dispatchable?(_), do: false

  @doc """
  The next scheduled occurrence at or after `now`, for the kanban **display**
  next_due. `active` means armed-for-the-next-occurrence, so the display next_due
  is computed `cron.next(now)`, never a stored timestamp. Returns nil when the
  role has no parseable schedule.
  """
  @spec next_due_from_cron(t(), DateTime.t()) :: DateTime.t() | nil
  def next_due_from_cron(%__MODULE__{schedule: schedule}, %DateTime{} = now) do
    case Shuttle.Cron.next_occurrence(schedule, now) do
      {:ok, %DateTime{} = next} -> next
      _ -> nil
    end
  end

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{validation_errors: []}), do: true
  def valid?(_), do: false

  @spec next_run_id(t(), DateTime.t()) :: String.t()
  def next_run_id(%__MODULE__{next_due_at: %DateTime{} = next_due_at}, _now) do
    Calendar.strftime(next_due_at, "%Y%m%dT%H%M%S%z")
  end

  def next_run_id(%__MODULE__{}, now) do
    Calendar.strftime(now, "%Y%m%dT%H%M%S%z")
  end

  @doc """
  Run id for a *scheduled* (non-ad-hoc) standing dispatch.

  A **resumed** run continues the awaiting run, so it must keep that run's id;
  a fresh scheduled run mints a new one from `next_due_at`. The distinction is
  written by the lifecycle verbs: `LifecycleStore.resume` preserves
  `review.run_id` and leaves `accepted_run_id` nil (the run continues), whereas
  `accept` sets `accepted_run_id == run_id` (the run is done — the next dispatch
  is a genuinely new run).

  Keeping the id on resume is load-bearing: the run id drives the review-comment
  window (`Dispatcher.run_window_start`/`parse_run_id`). `resume` sets
  `next_due_at = now`, so minting the id from `next_due_at` would put the window
  start *after* the `resume_mode: previous` directive that the same gesture filed
  a beat earlier — it falls outside its own run window and `check_resume_intent`
  silently falls back to `:fresh`. (That made the kanban Resume button behave
  exactly like New session — see gotcha-standing-role-resume-button-grayed.)
  """
  @spec dispatch_run_id(t(), DateTime.t()) :: String.t()
  def dispatch_run_id(%__MODULE__{run_id: run_id, review: review} = role, now) do
    accepted = review && review["accepted_run_id"]

    if is_binary(run_id) and run_id != "" and (is_nil(accepted) or accepted == "") do
      run_id
    else
      next_run_id(role, now)
    end
  end

  @spec ad_hoc_run_id(DateTime.t()) :: String.t()
  def ad_hoc_run_id(%DateTime{} = now) do
    "adhoc-#{DateTime.to_unix(now, :millisecond)}"
  end

  @spec ad_hoc_run_id?(String.t() | nil) :: boolean()
  def ad_hoc_run_id?("adhoc-" <> _), do: true
  def ad_hoc_run_id?(_), do: false

  @spec to_snapshot(t(), DateTime.t(), boolean()) :: map()
  def to_snapshot(%__MODULE__{} = role, now, running?) do
    %{
      fiber_id: role.fiber_id,
      state: state(role, now, running?),
      run_id: role.run_id,
      next_due_at: unix_ms(role.next_due_at),
      last_run_at: unix_ms(role.last_run_at),
      schedule: role.schedule,
      review: role.review,
      validation_errors: role.validation_errors
    }
  end

  defp validation_errors(%__MODULE__{} = role) do
    [
      validate_mode(role),
      validate_review_state(role),
      validate_next_due(role),
      validate_acceptance_ids(role)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp validate_mode(%__MODULE__{mode: "standing"}), do: nil
  defp validate_mode(%__MODULE__{mode: mode}), do: "kind must be standing, got #{inspect(mode)}"

  defp validate_review_state(%__MODULE__{review: review}) do
    state = review["state"] || "scheduled"

    if state in @canonical_review_states or state in @legacy_review_states do
      nil
    else
      "unsupported review state #{inspect(state)}"
    end
  end

  defp validate_next_due(%__MODULE__{review: review, next_due_at: next_due_at}) do
    state = review["state"] || "scheduled"

    cond do
      state in @scheduleable_review_states and is_nil(next_due_at) ->
        "scheduleable state #{state} requires next_due_at"

      state in @awaiting_review_states and not is_nil(next_due_at) and
          not ad_hoc_run_id?(string(review["run_id"])) ->
        "review state #{state} must clear next_due_at"

      true ->
        nil
    end
  end

  defp validate_acceptance_ids(%__MODULE__{review: review}) do
    state = review["state"] || "scheduled"
    run_id = string(review["run_id"])
    accepted_run_id = string(review["accepted_run_id"])

    cond do
      state == "accepted" and (is_nil(run_id) or run_id == "") ->
        "accepted review state requires run_id"

      state == "accepted" and accepted_run_id != run_id ->
        "accepted_run_id must match run_id in accepted review state"

      state in @awaiting_review_states and (is_nil(run_id) or run_id == "") ->
        "review state requires run_id"

      true ->
        nil
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      {:error, _} -> nil
    end
  end

  defp parse_datetime(%DateTime{} = value), do: value
  defp parse_datetime(_), do: nil

  defp map(value) when is_map(value), do: value
  defp map(_), do: %{}

  defp string(value) when is_binary(value), do: value
  defp string(nil), do: nil
  defp string(value), do: to_string(value)

  defp unix_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
  defp unix_ms(_), do: nil
end
