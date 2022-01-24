defmodule LogWatcher.FileWatcherSupervisor do
  @moduledoc """
  Supervisor that can start and link a `FileWatcher` GenServer
  for a given directory.
  """
  use DynamicSupervisor

  alias LogWatcher.FileWatcher

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Public interface. Start the `FileWatcher` GenServer for a session under
  supervision, and watch a log file.
  """
  @spec start_child_and_watch_file(String.t(), String.t(), String.t()) ::
          :ignore | {:ok, pid()} | {:error, term()}
  def start_child_and_watch_file(session_id, log_dir, log_file) do
    with {:ok, pid} <- start_child(session_id, log_dir),
         {:ok, _file} <- FileWatcher.add_watch(session_id, log_file, self()) do
      {:ok, pid}
    end
  end

  @doc """
  Public interface. Start the `FileWatcher` GenServer for a session under
  supervision. Returns the pid for an existing `FileWatcher` on the same
  directory.
  """
  @spec start_child(String.t(), String.t()) :: :ignore | {:ok, pid()} | {:error, term()}
  def start_child(session_id, log_dir) do
    spec = {LogWatcher.FileWatcher, session_id: session_id, log_dir: log_dir}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:ok, pid, _info} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      other ->
        other
    end
  end

  @doc false
  @impl true
  @spec init(term()) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
