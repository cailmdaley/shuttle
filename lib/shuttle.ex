defmodule Shuttle do
  @moduledoc """
  Shuttle — OTP-supervised orchestrator for felt constitution workers.

  Stage 2 (current): minimal dispatch path.
  Future stages: poller, watcher, snapshot surface, agent-API.
  """

  @doc """
  Returns the current version.
  """
  @spec version() :: String.t()
  def version, do: "0.1.0"
end

defmodule Shuttle.Application do
  @moduledoc """
  OTP application entrypoint.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Stage 3+: add poller, worker watcher supervisor, etc.
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Shuttle.Supervisor)
  end
end
