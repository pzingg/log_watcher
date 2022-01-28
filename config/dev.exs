import Config

# Configure your database
config :log_watcher, LogWatcher.Repo,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
