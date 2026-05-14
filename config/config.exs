import Config

config :shuttle,
  env: config_env(),
  # `:host` is intentionally left unset here. Per-daemon identity resolves at
  # runtime in `Shuttle.Poller.resolve_own_host_id/0`: SHUTTLE_HOST env var →
  # explicit app config (e.g. config/test.exs) → :inet.gethostname() →
  # "local". The historical literal "local" default was a no-op filter that
  # let remote and local daemons fight over the same fibers.
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
