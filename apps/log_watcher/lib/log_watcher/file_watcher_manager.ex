defmodule LogWatcher.FileWatcherManager do
  @moduledoc """
  Maintains a list of the filesystem directories that
  are being watched by a FileWatcher process, and forwards
  client `watch` and `unwatch` requests to the approprate
  FileWatcher.
  """
  use GenServer

  require Logger

  alias LogWatcher.FileWatcher
  alias LogWatcher.FileWatcherSupervisor

  # State is a list of watched directories.
  @type state() :: [String.t()]

  # Public interface

  @doc """
  Start a linked GenServer.
  """
  def start_link(arg) do
    GenServer.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def watch(session_id, command_id, command_name, file_path) do
    GenServer.call(__MODULE__, {:watch, session_id, command_id, command_name, file_path})
  end

  def unwatch(file_path, cleanup \\ false) do
    GenServer.call(__MODULE__, {:unwatch, file_path, cleanup})
  end

  def unwatch_dir(log_dir) do
    GenServer.call(__MODULE__, {:unwatch_dir, log_dir})
  end

  # Callbacks

  @doc false
  @impl true
  def init(_arg) do
    # Trap exits so we terminate if parent dies
    _ = Process.flag(:trap_exit, true)

    {:ok, []}
  end

  @doc false
  @impl true
  def handle_call({:watch, session_id, command_id, command_name, file_path}, _from, state) do
    {reply, state} = do_watch(session_id, command_id, command_name, file_path, state)
    {:reply, reply, state}
  end

  def handle_call({:unwatch, file_path, cleanup}, _from, state) do
    {reply, state} = do_unwatch(file_path, cleanup, state)
    {:reply, reply, state}
  end

  def handle_call({:unwatch_dir, log_dir}, _from, state) do
    {reply, state} = remove_watcher(log_dir, state)
    {:reply, reply, state}
  end

  @doc false
  @impl true
  def handle_info({:DOWN, ref, pid, reason}, state) do
    _ = Logger.debug("FileWatcherManager :DOWN #{inspect(ref)} #{inspect(pid)} #{reason}")
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    _ = Logger.debug("FileWatcherManager :EXIT #{inspect(pid)} #{reason}")
    {:noreply, state}
  end

  def handle_info(unexpected, state) do
    _ = Logger.debug("FileWatcherManager unexpected #{inspect(unexpected)}")
    {:noreply, state}
  end

  @doc false
  @impl true
  def terminate(reason, _state) do
    _ = Logger.debug("FileWatcherManager terminate #{reason}")
    :ok
  end

  # Private functions

  defp do_watch(session_id, command_id, command_name, file_path, state) do
    log_dir = Path.dirname(file_path)
    {result, state} = find_or_add_watcher(log_dir, state)

    case result do
      :ok ->
        file_name = Path.basename(file_path)
        watch_result = FileWatcher.watch(log_dir, session_id, command_id, command_name, file_name)
        {watch_result, state}

      error ->
        {error, state}
    end
  end

  defp do_unwatch(file_path, cleanup, state) do
    log_dir = Path.dirname(file_path)

    if Enum.member?(state, log_dir) do
      file_name = Path.basename(file_path)
      result = FileWatcher.unwatch(log_dir, file_name, cleanup)

      case result do
        {:ok, :gone} ->
          {:ok, List.delete(state, log_dir)}

        {:ok, _} ->
          {:ok, state}

        error ->
          {error, state}
      end
    else
      {:ok, state}
    end
  end

  defp find_or_add_watcher(log_dir, state) do
    if Enum.member?(state, log_dir) do
      {:ok, state}
    else
      case FileWatcherSupervisor.start_watcher(log_dir) do
        {:ok, _pid} ->
          {:ok, [log_dir | state]}

        :ignore ->
          {:ignore, state}

        error ->
          {error, state}
      end
    end
  end

  defp remove_watcher(log_dir, state) do
    if Enum.member?(state, log_dir) do
      FileWatcher.kill(log_dir)
      {:ok, List.delete(state, log_dir)}
    else
      {:ok, state}
    end
  end
end
