import Config

# Configure Mix tasks and generators
config :log_watcher,
  ecto_repos: [LogWatcher.Repo]

if config_env() == :test do
  # 30 minute timeout
  config :log_watcher, LogWatcher.Repo,
    pool: Ecto.Adapters.SQL.Sandbox,
    ownership_timeout: 1_800_000
end

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason
