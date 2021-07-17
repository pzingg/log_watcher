use Mix.Config

# Configure your database
config :log_watcher, LogWatcher.Repo,
  username: "postgres",
  password: "postgres",
  database: "log_watcher_dev",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
