defmodule Shuttle.CLI do
  @moduledoc """
  CLI entrypoint for the shuttle escript.

  Subcommands:
    dispatch <fiber-id>   — one-shot dispatch for a specific fiber
    start                 — start the daemon
    status                — human-readable status dump
    snapshot              — JSON snapshot for consumers
    version               — print version
  """

  alias Shuttle.Dispatcher

  def main(args) do
    case args do
      ["dispatch", fiber_id] ->
        case Dispatcher.dispatch(fiber_id) do
          {:ok, session} ->
            IO.puts("Dispatched #{fiber_id}")
            IO.puts("  Session: #{session}")
            IO.puts("  Attach:  tmux attach -t #{session}")

          {:error, :not_found} ->
            IO.puts(:stderr, "Fiber not found: #{fiber_id}")
            System.halt(1)

          {:error, :closed} ->
            IO.puts(:stderr, "Fiber #{fiber_id} is closed; refusing to dispatch.")
            System.halt(1)

          {:error, :already_running} ->
            IO.puts(:stderr, "Shuttle worker already running for #{fiber_id}")
            System.halt(0)

          {:error, reason} ->
            IO.puts(:stderr, "Dispatch failed: #{reason}")
            System.halt(1)
        end

      ["start"] ->
        IO.puts("Starting Shuttle daemon...")
        {:ok, _} = Application.ensure_all_started(:shuttle)
        IO.puts("Shuttle running. Press Ctrl+C to exit.")
        Process.sleep(:infinity)

      ["snapshot"] ->
        case Application.ensure_all_started(:shuttle) do
          {:ok, _} ->
            snap = Shuttle.Poller.snapshot()
            IO.puts(Jason.encode!(snap))

          _ ->
            IO.puts(:stderr, "Failed to start Shuttle")
            System.halt(1)
        end

      ["status"] ->
        case Application.ensure_all_started(:shuttle) do
          {:ok, _} ->
            snap = Shuttle.Poller.snapshot()
            print_status(snap)

          _ ->
            IO.puts(:stderr, "Failed to start Shuttle")
            System.halt(1)
        end

      ["version"] ->
        IO.puts(Shuttle.version())

      _ ->
        IO.puts("Usage: shuttle <command>")
        IO.puts("")
        IO.puts("Commands:")
        IO.puts("  dispatch <fiber-id>  Dispatch a worker for a specific fiber")
        IO.puts("  start                Start the daemon")
        IO.puts("  snapshot             Print JSON snapshot of current state")
        IO.puts("  status               Human-readable status dump")
        IO.puts("  version              Print version")
        System.halt(1)
    end
  end

  @doc false
  def print_status(snap) do
    IO.puts("Shuttle v#{Shuttle.version()} — #{snap.host}")
    IO.puts("Poll at: #{DateTime.from_unix!(snap.poll_at, :millisecond)}")
    IO.puts("")

    if snap.eligible == [] do
      IO.puts("No running workers.")
    else
      IO.puts("Running workers (#{length(snap.eligible)}):")

      Enum.each(snap.eligible, fn w ->
        IO.puts("  • #{w.fiber_id}")

        IO.puts(
          "    session: #{w.tmux_session}  agent: #{w.agent}  runtime: #{w.runtime_seconds}s"
        )
      end)
    end

    IO.puts("")

    if snap.retrying == [] do
      IO.puts("No retry queue.")
    else
      IO.puts("Retry queue (#{length(snap.retrying)}):")

      Enum.each(snap.retrying, fn r ->
        IO.puts("  • #{r.fiber_id} — attempt #{r.attempt}, due in #{r.due_in_ms}ms")
      end)
    end

    IO.puts("")
    print_standing_roles(Map.get(snap, :standing_roles, []))
  end

  defp print_standing_roles([]) do
    IO.puts("No standing roles.")
  end

  defp print_standing_roles(roles) do
    IO.puts("Standing roles (#{length(roles)}):")

    Enum.each(roles, fn role ->
      IO.puts("  • #{role.fiber_id} — #{role.state}")
      print_optional("run", role.run_id)
      print_optional("next due", format_unix_ms(role.next_due_at))
      print_optional("last run", format_unix_ms(role.last_run_at))

      if role.validation_errors != [] do
        IO.puts("    validation: #{Enum.join(role.validation_errors, "; ")}")
      end
    end)
  end

  defp print_optional(_label, nil), do: :ok
  defp print_optional(_label, ""), do: :ok
  defp print_optional(label, value), do: IO.puts("    #{label}: #{value}")

  defp format_unix_ms(nil), do: nil

  defp format_unix_ms(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end
end
