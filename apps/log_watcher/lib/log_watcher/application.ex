defmodule LogWatcher.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      # Start the Ecto repository
      LogWatcher.Repo,
      # Dynamically supervise per-directory FileWatcher processes
      {LogWatcher.FileWatcherSupervisor, name: LogWatcher.FileWatcherSupervisor},
      # Map files and directories being watched to FileWatcher processes
      {LogWatcher.FileWatcherManager, name: LogWatcher.FileWatcherManager},
      # Dynamically supervise per-command ScriptRunner processes
      {LogWatcher.CommandSupervisor, name: LogWatcher.CommandSupervisor},
      # Map command or job ids to ScriptRunner processes
      {LogWatcher.CommandManager, name: LogWatcher.CommandManager},
      # Asyncronously run the OS processes running the scripts
      {Task.Supervisor, name: LogWatcher.TaskSupervisor},
      # Start the PubSub system
      {Phoenix.PubSub, name: LogWatcher.PubSub},
      # Run jobs via a PostgreSQL database
      {Oban, oban_config()},
      # Pipeline will be restarted for each test.
      {LogWatcher.Pipeline, []}
      # Start a worker by calling: LogWatcher.Worker.start_link(arg)
      # {LogWatcher.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LogWatcher.Supervisor)
  end

  def oban_config() do
    Application.fetch_env!(:log_watcher, Oban)
  end
end
