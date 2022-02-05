defmodule LogWatcher.MixProject do
  use Mix.Project

  def project do
    [
      app: :log_watcher,
      version: "0.2.0",
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
      consolidate_protocols: Mix.env() == :prod,
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
      {:broadway, "~> 1.0"},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:dotenvy, "~> 0.3"},
      {:ecto_sql, "~> 3.6"},
      {:ecto_ulid, "~> 0.3"},
      {:faker, "~> 0.16", only: [:dev, :test]},
      {:file_system, "~> 0.2"},
      {:gen_stage, "~> 1.1"},
      {:gproc, "~> 0.9"},
      {:jason, "~> 1.2"},
      {:oban, "~> 2.7"},
      {:phoenix, "~> 1.6.2"},
      {:phoenix_pubsub, "~> 2.0"},
      {:postgrex, "~> 0.15"},
      {:telemetry, "~> 1.0"},
      {:translations, in_umbrella: true}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    ecto_setup =
      if Mix.env() == :test do
        ["ecto.create", "ecto.migrate"]
      else
        ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"]
      end

    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ecto_setup,
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
