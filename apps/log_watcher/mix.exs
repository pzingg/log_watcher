defmodule LogWatcher.MixProject do
  use Mix.Project

  def project do
    [
      app: :log_watcher,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.11",
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_deps: :apps_direct,
        plt_add_apps: [:oban],
        ignore_warnings: "dialyzer.ignore-warnings"
      ],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {LogWatcher.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:dotenvy, "~> 0.3"},
      {:ecto_sql, "~> 3.6"},
      {:faker, "~> 0.16", only: :test},
      {:file_system, "~> 0.2"},
      {:gproc, "~> 0.9"},
      {:jason, "~> 1.2"},
      {:oban, "~> 2.7"},
      {:phoenix_pubsub, "~> 2.0"},
      {:postgrex, "~> 0.15"},
      {:typed_struct, "~> 0.2"},
      # {:typed_struct_ecto_changeset, "~> 0.1"}
      {:typed_struct_ecto_changeset, path: "/home/pzingg/Projects/elixir/typed_struct_ecto_changeset"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
