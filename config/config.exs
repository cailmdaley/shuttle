import Config

config :shuttle,
  env: config_env(),
  start_poller: true

import_config "#{config_env()}.exs"
