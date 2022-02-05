import Config
import Dotenvy

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

current_dir = File.cwd!()
parent_dir = Path.dirname(current_dir) |> Path.basename()

IO.puts("evaluating runtime configuration (config/runtime.exs)")
IO.puts("in directory '#{current_dir}'")
IO.puts("for target '#{config_target()}' in '#{config_env()}' environment")

# For environment settings, read e.g ".env", "dev.env", "dev.local.env"
# Search in current directory (if running under Mix in project root or under a release),
# or two directories up (if running under Mix in umbrella app directory).
current_dir_env_paths = ["./.env", "./#{config_env()}.env", "./#{config_env()}.local.env"]

umbrella_env_paths =
  if parent_dir == "apps" do
    current_dir_env_paths ++
      Enum.map(current_dir_env_paths, fn path ->
        String.replace_leading(path, "./", "../../")
      end)
  else
    current_dir_env_paths
  end

source!(umbrella_env_paths)

{oban_queues, oban_plugins} =
  if config_env() == :test do
    # Oban testing. See https://hexdocs.pm/oban/Oban.html#module-testing
    # Disable all job dispatching by setting queues: false or queues: nil
    # Disable plugins via plugins: false.
    # {false, false}
    # But we apparently need the queue and the Repeater plugin...
    {[commands: 10], [Oban.Plugins.Repeater]}
  else
    {[commands: 10], [{Oban.Plugins.Pruner, max_age: 600}]}
  end

config :log_watcher, Oban,
  name: Oban,
  repo: LogWatcher.Repo,
  queues: oban_queues,
  plugins: oban_plugins,
  shutdown_grace_period: 1_000

db_name = env!("DB_NAME", :string!)
db_port = env!("DB_PORT", :integer!)
IO.puts("using database '#{db_name}' on port #{db_port} for LogWatcher.Repo")

config :log_watcher, LogWatcher.Repo,
  username: env!("DB_USER", :string!),
  password: env!("DB_PASSWORD", :string!),
  hostname: env!("DB_HOST", :string!),
  database: db_name,
  port: db_port,
  pool_size: env!("DB_POOL_SIZE", :integer!)

  # The block below contains prod specific runtime configuration.
if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.

  # You can generate a secret key by calling: mix phx.gen.secret
  secret_key_base = env!("SECRET_KEY_BASE")

  config :example, ExampleWeb.Endpoint,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/plug_cowboy/Plug.Cowboy.html
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(env!("PORT", "4000"))
    ],
    secret_key_base: secret_key_base

  # ## Using releases
  #
  # If you are doing OTP releases, you need to instruct Phoenix
  # to start each relevant endpoint:
  #
  #     config :example, ExampleWeb.Endpoint, server: true
  #
  # Then you can assemble a release by calling `mix release`.
  # See `mix help release` for more information.
end
