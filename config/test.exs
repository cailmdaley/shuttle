import Config

config :shuttle,
  env: :test,
  start_poller: false,
  start_remote_registry: false,
  remotes: []

config :shuttle, ShuttleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "testsecretkeybasetestsecretkeybasetestsecretkeybasetestsecretkeybase",
  server: false
