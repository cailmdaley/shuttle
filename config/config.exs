import Config

config :shuttle,
  env: config_env(),
  start_poller: true

config :shuttle, ShuttleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Shuttle.PubSub

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "agents.exs"
import_config "#{config_env()}.exs"
