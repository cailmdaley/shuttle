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
    # In escript mode, Mix compile-time config (config/dev.exs) is not loaded
    # into the application environment automatically. Ensure the HTTP endpoint
    # has what it needs to bind. If the config is already present (Mix test /
    # Mix run context), this is a no-op.
    maybe_configure_endpoint()

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

  # Ensure the HTTP endpoint has its :http binding config.
  #
  # In escript mode the runtime application env doesn't have values from
  # config/dev.exs, so we seed them from the SHUTTLE_PORT env var (default 4000).
  # When running under Mix (tests, `mix run`), the env is already populated and
  # this is a no-op.
  # Ensure the HTTP endpoint has what it needs to bind.
  #
  # In the common case (dev.exs loaded in escript mode), config/dev.exs already
  # sets server: true. This fallback handles edge cases where config is absent
  # (e.g., custom environments, future release builds, test harness overrides).
  # The SHUTTLE_PORT env var overrides the port.
  defp maybe_configure_endpoint do
    existing = Application.get_env(:shuttle, ShuttleWeb.Endpoint, [])

    # Only patch if server: true is not already set and http config is missing.
    # When dev.exs is loaded, both are present and this is a no-op.
    if Keyword.get(existing, :server) == true and Keyword.has_key?(existing, :http) do
      :ok
    else
      port =
        existing
        |> Keyword.get(:http, [])
        |> Keyword.get(:port, System.get_env("SHUTTLE_PORT", "4000") |> String.to_integer())

      secret_key_base =
        Keyword.get(
          existing,
          :secret_key_base,
          System.get_env(
            "SHUTTLE_SECRET_KEY_BASE",
            "shuttlelocaldevkeybaseshuttlelocaldevkeybaseshuttlelocaldevkeybase"
          )
        )

      merged =
        Keyword.merge(existing,
          http: [ip: {127, 0, 0, 1}, port: port],
          adapter: Keyword.get(existing, :adapter, Bandit.PhoenixAdapter),
          pubsub_server: Shuttle.PubSub,
          url: Keyword.get(existing, :url, [host: "localhost"]),
          server: true,
          secret_key_base: secret_key_base
        )

      Application.put_env(:shuttle, ShuttleWeb.Endpoint, merged)
    end
  end
end
