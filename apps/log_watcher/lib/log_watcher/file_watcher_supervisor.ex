defmodule LogWatcher.FileWatcherSupervisor do
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, opts)
  end

  def start_child(session_id, session_log_path) do
    spec = {LogWatcher.FileWatcher, session_id: session_id, session_log_path: session_log_path}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
