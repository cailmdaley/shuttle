import Config

config :shuttle, ShuttleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: false,
  # Required for the escript daemon to actually bind the TCP port.
  # Phoenix won't start the HTTP server without this explicit flag.
  server: true,
  secret_key_base: "shuttlelocaldevkeybaseshuttlelocaldevkeybaseshuttlelocaldevkeybase"
