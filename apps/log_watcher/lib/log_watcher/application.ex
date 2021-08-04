defmodule LogWatcher.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      # Start the Ecto repository
      LogWatcher.Repo,
      # Monitor long running scripts via Elixir Tasks.
      {Elixir.Task.Supervisor, name: LogWatcher.TaskSupervisor},
      # Monitor jobs started by Oban
      {LogWatcher.TaskMonitor, name: LogWatcher.TaskMonitor},
      # Start the PubSub system
      {Phoenix.PubSub, name: LogWatcher.PubSub},
      # Run jobs via a PostgreSQL database
      {Oban, oban_config()}
      # Start a worker by calling: LogWatcher.Worker.start_link(arg)
      # {LogWatcher.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LogWatcher.Supervisor)
  end

  def oban_config() do
    Application.fetch_env!(:log_watcher, Oban)
  end
end
