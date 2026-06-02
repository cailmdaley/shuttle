defmodule Shuttle.CronTest do
  use ExUnit.Case

  alias Shuttle.Cron

  test "next_occurrence honors weekday schedules in the target timezone" do
    {:ok, after_at, _} = DateTime.from_iso8601("2026-05-04T06:00:00Z")

    assert {:ok, next} =
             Cron.next_occurrence(%{"expr" => "0 9 * * 1-5", "tz" => "Europe/Paris"}, after_at)

    assert DateTime.to_iso8601(next) == "2026-05-04T09:00:00+02:00"
  end

  test "next_occurrence supports slash steps" do
    {:ok, after_at, _} = DateTime.from_iso8601("2026-06-02T07:15:00Z")

    assert {:ok, next} = Cron.next_occurrence(%{"expr" => "0 */2 * * *", "tz" => "UTC"}, after_at)

    assert DateTime.to_unix(next) == 1_780_387_200
  end
end
