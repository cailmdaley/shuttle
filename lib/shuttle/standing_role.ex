defmodule Shuttle.StandingRole do
  @moduledoc """
  Parses and classifies `shuttle.kind: standing` fiber declarations.

  Standing roles are still felt fibers. Shuttle interprets the `shuttle:` block
  plus the document's `status`/`tempered` to decide whether a role is sleeping,
  due, or running. "Awaiting review" and "accepted/composted" are document facts
  (`status:closed` + untempered / `tempered`), not a `review.state` axis — there
  is none; the schedule-derived phase here only answers sleeping/due/running for
  an armed role.
  """

  defstruct [
    :fiber_id,
    :mode,
    :schedule,
    :next_due_at,
    :last_run_at,
    :run_id,
    validation_errors: []
  ]

  @type t :: %__MODULE__{
          fiber_id: String.t(),
          mode: String.t() | nil,
          schedule: map(),
          next_due_at: DateTime.t() | nil,
          last_run_at: DateTime.t() | nil,
          run_id: String.t() | nil,
          validation_errors: [String.t()]
        }

  @spec from_map(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def from_map(fiber_id, data) when is_map(data) do
    role = %__MODULE__{
      fiber_id: fiber_id,
      mode: string(data["kind"] || data["mode"]),
      schedule: map(data["schedule"]),
      next_due_at: parse_datetime(data["next_due_at"]),
      last_run_at: parse_datetime(data["last_run_at"]),
      run_id: nil
    }

    {:ok, %{role | validation_errors: validation_errors(role)}}
  end

  @spec standing?(t() | nil) :: boolean()
  def standing?(%__MODULE__{mode: "standing"}), do: true
  def standing?(_), do: false

  @doc """
  The schedule-derived display phase for an armed role, computed from cron +
  liveness — NOT from `review.state` or `enabled` (neither axis exists).
  "Awaiting review", "accepted", and "paused/draft" are document facts
  (`status:closed` + untempered / `tempered`, and `status:open`), surfaced by the
  kanban classifier from the document, not derived here. This function only
  answers the schedule question for an armed role (`status: active`): is a worker
  live, is its next tick due, or is it sleeping.
  """
  @spec state(t(), DateTime.t(), boolean()) :: String.t()
  def state(%__MODULE__{} = role, now, running?) do
    cond do
      # A live worker is a fact, not a schedule conclusion — it wins even for a
      # role paused with `--no-kill`, so the card reads true until the run ends.
      running? -> "running"
      due_by_schedule?(role, now) -> "due"
      true -> "scheduled"
    end
  end

  # Display window for the `state/3` "due" phase — the recent past in which a
  # fired tick still reads as "due" before the poll dispatches it and the
  # document flips to closed. Cron occurrences are strictly-after, so a fixed
  # lookback window is how a just-fired tick is recognized (mirrors the dispatch
  # path's `due_by_cron?` window, sized for display rather than the poll cadence).
  @display_due_window_ms 90_000

  # Display due-ness for `state/3`: a valid role whose cron schedule fired a tick
  # inside `(now - window, now]`. Pure cron — no stored next_due_at, no review
  # gate.
  defp due_by_schedule?(%__MODULE__{schedule: schedule} = role, %DateTime{} = now) do
    window_start = DateTime.add(now, -@display_due_window_ms, :millisecond)

    valid?(role) and
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

  defp due_by_schedule?(_, _), do: false

  @doc """
  Cron-derived due check for the **dispatch** path: true iff the schedule fired a
  tick inside the lookback `(now - window_ms, now]`.

  Due-ness is computed straight from the cron `schedule` and `now`, NOT from a
  stored `next_due_at`. This is a pure primitive — the *meaning* of the lookback
  is the caller's. The poller (`standing_role_due?`) anchors it at the role's last
  service (`now - last_serviced`), so "a tick in the lookback" means "an
  occurrence elapsed since we last ran" — i.e. the schedule self-catches a fire
  the daemon slept through, however late, rather than skipping it.

  A single catch-up fires, not a backlog: once a role fires its document flips
  `active → closed`, `eligible?` excludes closed, and the run advances the anchor
  to ~now — so the `active → closed → accept` transition is the per-cycle gate,
  not a timestamp, and an awaiting role never re-fires until a human tempers it.

  It does NOT consult `review.state` — the dispatch gate is the felt document's
  `status`/`tempered` (the poller checks those before calling this).
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

  # Dispatch-path validity: a standing role with a parseable schedule. Both the
  # dispatch and display paths gate on schedule alone — there are no
  # review/next_due validations: the document, not a review overlay, is the
  # truth, and doc-sourced roles carry no stored next_due_at or review block.
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
  Run id for a *scheduled* (non-ad-hoc) standing dispatch — a display label for
  the prompt's `Run:` line, minted from `now`.

  It is not load-bearing for resume continuity: `Dispatcher.run_window_start`
  derives the resume window from felt history (the last worker-exit event's
  timestamp), not from this id. The id is therefore free to be a fresh
  timestamp every dispatch.
  """
  @spec dispatch_run_id(t(), DateTime.t()) :: String.t()
  def dispatch_run_id(%__MODULE__{} = role, now) do
    next_run_id(role, now)
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
      validation_errors: role.validation_errors
    }
  end

  # Validity is the document's intrinsic shape: a standing role with a parseable
  # cron schedule. There are no review/next_due validations — the document
  # (status + tempered) is the truth, and doc-sourced roles carry no review block
  # or stored next_due_at to validate against.
  defp validation_errors(%__MODULE__{} = role) do
    [
      validate_mode(role),
      validate_schedule(role)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp validate_mode(%__MODULE__{mode: "standing"}), do: nil
  defp validate_mode(%__MODULE__{mode: mode}), do: "kind must be standing, got #{inspect(mode)}"

  defp validate_schedule(%__MODULE__{schedule: schedule}) do
    case Shuttle.Cron.next_occurrence(schedule, DateTime.utc_now()) do
      {:ok, %DateTime{}} -> nil
      _ -> "schedule must be a parseable cron expression"
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
