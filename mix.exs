defmodule LogWatcherUmbrella.MixProject do
  use Mix.Project

  # Umbrella projects require :apps_path and :apps
  def project do
    [
      app: :log_watcher_umbrella,
      apps_path: "apps",
      apps: [:translations, :log_watcher, :example],
      version: "0.2.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: []
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  # Umbrella projects will include each app's dependencies
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
