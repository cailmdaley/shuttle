defmodule Shuttle.CLI do
  @moduledoc """
  CLI entrypoint for the shuttle escript.

  Subcommands:
    dispatch <fiber-id>   — one-shot dispatch for a specific fiber
    version               — print version

  Future stages:
    start                 — start the daemon
    status                — human-readable status dump
    snapshot              — JSON snapshot for consumers
    agents                — list configured agents
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

      ["version"] ->
        IO.puts(Shuttle.version())

      _ ->
        IO.puts("Usage: shuttle dispatch <fiber-id> | shuttle version")
        System.halt(1)
    end
  end
end
