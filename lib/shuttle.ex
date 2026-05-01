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
      {Phoenix.PubSub, name: Shuttle.PubSub},
      {DynamicSupervisor, strategy: :one_for_one, name: Shuttle.WatcherSupervisor}
    ]

    children =
      if Application.get_env(:shuttle, :start_poller, true) do
        children ++ [Shuttle.Poller]
      else
        children
      end

    children =
      if Application.get_env(:shuttle, :start_endpoint, true) do
        children ++ [ShuttleWeb.Endpoint]
      else
        children
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Shuttle.Supervisor)
  end
end
