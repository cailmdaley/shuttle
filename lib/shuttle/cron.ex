defmodule Shuttle.Cron do
  @moduledoc """
  Small standard five-field cron helper for daemon-owned lifecycle transitions.

  Shuttle's Go CLI uses robfig/cron for the same grammar. This module covers the
  standard field shapes used by Shuttle standing roles: wildcards, ranges,
  comma lists, and slash steps over minute/hour/day/month/dow.
  """

  @field_specs [
    minute: {0, 59},
    hour: {0, 23},
    day: {1, 31},
    month: {1, 12},
    dow: {0, 6}
  ]

  @spec next_occurrence(map(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, String.t()}
  def next_occurrence(%{"expr" => expr, "tz" => tz}, %DateTime{} = after_at)
      when is_binary(expr) and is_binary(tz) do
    with {:ok, fields} <- parse_expr(expr),
         {:ok, local_after} <- DateTime.shift_zone(after_at, tz) do
      scan_next(fields, local_after)
    else
      {:error, %ArgumentError{} = error} -> {:error, Exception.message(error)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def next_occurrence(%{"expr" => expr, "timezone" => tz}, after_at),
    do: next_occurrence(%{"expr" => expr, "tz" => tz}, after_at)

  def next_occurrence(_schedule, _after_at), do: {:error, "schedule requires expr and tz"}

  defp parse_expr(expr) do
    parts = String.split(expr)

    if length(parts) == 5 do
      @field_specs
      |> Enum.zip(parts)
      |> Enum.reduce_while({:ok, %{}}, fn {{name, {min, max}}, raw}, {:ok, fields} ->
        case parse_field(raw, min, max) do
          {:ok, values} -> {:cont, {:ok, Map.put(fields, name, MapSet.new(values))}}
          {:error, reason} -> {:halt, {:error, "#{name}: #{reason}"}}
        end
      end)
    else
      {:error, "cron expression must have exactly 5 fields"}
    end
  end

  defp parse_field(raw, min, max) do
    raw
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case parse_part(part, min, max) do
        {:ok, values} -> {:cont, {:ok, Enum.into(values, acc)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} when map_size(values) > 0 -> {:ok, values}
      {:ok, _} -> {:error, "empty field"}
      error -> error
    end
  end

  defp parse_part(part, min, max) do
    case String.split(part, "/", parts: 2) do
      [base] ->
        parse_base(base, min, max)

      [base, step_raw] ->
        with {step, ""} when step > 0 <- Integer.parse(step_raw),
             {:ok, values} <- parse_base(base, min, max) do
          {:ok, Enum.take_every(values, step)}
        else
          _ -> {:error, "invalid step #{inspect(step_raw)}"}
        end
    end
  end

  defp parse_base("*", min, max), do: {:ok, Enum.to_list(min..max)}

  defp parse_base(base, min, max) do
    case String.split(base, "-", parts: 2) do
      [single] ->
        parse_int(single, min, max)
        |> case do
          {:ok, value} -> {:ok, [value]}
          error -> error
        end

      [first, last] ->
        with {:ok, a} <- parse_int(first, min, max),
             {:ok, b} <- parse_int(last, min, max),
             true <- a <= b do
          {:ok, Enum.to_list(a..b)}
        else
          false -> {:error, "range start must be <= range end"}
          error -> error
        end
    end
  end

  defp parse_int(raw, min, max) do
    case Integer.parse(raw) do
      {value, ""} when value >= min and value <= max -> {:ok, value}
      {value, ""} -> {:error, "#{value} outside #{min}..#{max}"}
      _ -> {:error, "invalid integer #{inspect(raw)}"}
    end
  end

  defp scan_next(fields, local_after) do
    local_after
    |> DateTime.add(60 - local_after.second, :second)
    |> Stream.iterate(&DateTime.add(&1, 60, :second))
    |> Enum.reduce_while(0, fn candidate, minutes ->
      cond do
        minutes > 366 * 24 * 60 ->
          {:halt, {:error, "no next occurrence found within one year"}}

        matches?(fields, candidate) ->
          {:halt, {:ok, candidate}}

        true ->
          {:cont, minutes + 1}
      end
    end)
  end

  defp matches?(fields, %DateTime{} = candidate) do
    MapSet.member?(fields.minute, candidate.minute) and
      MapSet.member?(fields.hour, candidate.hour) and
      MapSet.member?(fields.day, candidate.day) and
      MapSet.member?(fields.month, candidate.month) and
      MapSet.member?(fields.dow, rem(Date.day_of_week(candidate), 7))
  end
end
