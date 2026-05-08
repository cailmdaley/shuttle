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
      run_id: string(get_in(data, ["review", "run_id"]))
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
      running? -> "running"
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
