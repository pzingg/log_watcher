import Config

config :logger, level: :debug

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :log_watcher, LogWatcher.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  ownership_timeout: 1_800_000
