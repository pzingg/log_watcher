import Config

# Do not print debug messages in production
config :logger, level: :info

# Configure your database
config :log_watcher, LogWatcher.Repo,
  pool_size: 15
