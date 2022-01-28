defmodule LogWatcher.FileWatcherSupervisor do
  @moduledoc """
  Supervises dynamically started FileWatcher child processes.
  The FileWatcher GenServer processes can be accessed via `command_id`.
  """
  use DynamicSupervisor

  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start_watcher(log_dir) do
    child_spec = {LogWatcher.FileWatcher, log_dir}

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @impl true
  def init(_arg) do
    # :one_for_one strategy: if a child process crashes, only that process is restarted.
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
