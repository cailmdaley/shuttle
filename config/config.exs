import Config

config :shuttle,
  env: config_env(),
  host: "local",
  start_poller: true,
  start_remote_registry: true,
  # Per-host snapshots from remote Shuttle daemons reachable via
  # SSH tunnels. Each entry: %{name: String, url: String,
  # poll_interval_ms: pos_integer (default 5000), request_timeout_ms:
  # pos_integer (default 2000), stale_multiplier: pos_integer (default
  # 2)}. Empty by default — local-only setups pay nothing.
  #
  # Example, after running `shuttle tunnels install`:
  #
  #   remotes: [
  #     %{name: "candide", url: "http://localhost:4001"}
  #   ]
  remotes: []

config :shuttle, ShuttleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Shuttle.PubSub

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
