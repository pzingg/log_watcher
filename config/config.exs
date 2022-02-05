# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Configures the endpoint
config :example, ExampleWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "5PdLKC+gWP9W+PmmSk9WPIxdnWLf8tViZy1lfcSM9cATZrsNOI9thDKtyBcl2bPk",
  render_errors: [view: ExampleWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: LogWatcher.PubSub,
  live_view: [signing_salt: "zYjNWoE7"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.14.0",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2016 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/example/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure Mix tasks and generators
config :log_watcher,
  ecto_repos: [LogWatcher.Repo]

# Configures database migration defaults
config :log_watcher, LogWatcher.Repo,
  migration_primary_key: [name: :id, type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

# Configure the session store
# config :log_watcher,
#  script_dir: Path.join([:code.priv_dir(:log_watcher), "mock_command"]),
#  session_base_dir: Path.join([:code.priv_dir(:log_watcher), "mock_command", "sessions"]),
#  session_log_dir:
#    Path.join([:code.priv_dir(:log_watcher), "mock_command", "sessions", ":tag", "output"])

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
