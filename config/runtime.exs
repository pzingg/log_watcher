import Config
import Dotenvy

current_dir = File.cwd!()
parent_dir = Path.dirname(current_dir) |> Path.basename()

IO.puts("evaluating runtime configuration (config/runtime.exs)")
IO.puts("in directory '#{current_dir}'")
IO.puts("for target '#{config_target()}' in '#{config_env()}' environment")

# For environment settings, read e.g ".env", "dev.env", "dev.local.env"
# Search in current directory (if running under Mix in project root or under a release),
# or two directories up (if running under Mix in umbrella app directory).
{default_name, default_log_dir, env_paths} =
  if parent_dir == "apps" do
    {Path.basename(current_dir),
      Path.dirname(current_dir) |> Path.dirname(),
      ["./.env", "./#{config_env()}.env", "./#{config_env()}.local.env",
        "../../.env", "../../#{config_env()}.env", "../../#{config_env()}.local.env"]}
  else
    {"rservex",
      current_dir,
      ["./.env", "./#{config_env()}.env", "./#{config_env()}.local.env"]}
  end

source!(env_paths)

config :log_watcher, Oban,
  repo: LogWatcher.Repo,
  plugins: [{Oban.Plugins.Pruner, max_age: 600}],
  queues: [log_watcher: 10]

config :log_watcher, LogWatcher.Repo,
  username: env!("DB_USER", :string!),
  password: env!("DB_PASSWORD", :string!),
  database: env!("DB_NAME", :string!),
  hostname: env!("DB_HOST", :string!),
  port: env!("DB_PORT", :integer!),
  pool_size: env!("DB_POOL_SIZE", :integer!)
