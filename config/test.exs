import Config

config :shuttle,
  env: :test,
  # Pin the test daemon identity so all tests start from a predictable
  # `own_host_id` regardless of the machine running them. Tests that need to
  # exercise host-pin matching still pass explicit `own_host_id:` opts.
  host: "local",
  start_poller: false,
  start_remote_registry: false,
  remotes: []

config :shuttle, ShuttleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "testsecretkeybasetestsecretkeybasetestsecretkeybasetestsecretkeybase",
  server: false
