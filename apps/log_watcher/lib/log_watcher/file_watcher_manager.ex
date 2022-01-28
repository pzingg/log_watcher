defmodule LogWatcher.FileWatcherManager do
  @moduledoc """
  Supervisor that can start and link a `FileWatcher` GenServer
  for a given directory.
  """
  use GenServer

  require Logger

  alias LogWatcher.FileWatcher

  # State is a map from directories to GenServer servers.
  @type state() :: %{required(String.t()) => pid()}

  # Public interface

  @doc """
  Start a linked GenServer.
  """
  def start_link(arg) do
    GenServer.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def watch(session_id, command_id, file_path) do
    GenServer.call(__MODULE__, {:watch, session_id, command_id, file_path})
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

    {:ok, %{}}
  end

  @doc false
  @impl true
  def handle_call({:watch, session_id, command_id, file_path}, _from, state) do
    {reply, state} = do_watch(session_id, command_id, file_path, state)
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
    Logger.error("FileWatcherManager :DOWN #{inspect(ref)} #{inspect(pid)} #{reason}")
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.error("FileWatcherManager :EXIT #{inspect(pid)} #{reason}")
    {:noreply, state}
  end

  def handle_info(unexpected, state) do
    Logger.error("FileWatcherManager unexpected #{inspect(unexpected)}")
    {:noreply, state}
  end

  @doc false
  @impl true
  def terminate(reason, _state) do
    Logger.error("FileWatcherManager terminate #{reason}")
    :ok
  end

  # Private functions

  defp do_watch(session_id, command_id, file_path, state) do
    log_dir = Path.dirname(file_path)

    {pid_result, state} = find_or_add_watcher(session_id, log_dir, state)

    case pid_result do
      {:ok, pid} ->
        file_name = Path.basename(file_path)
        {GenServer.call(pid, {:watch, command_id, file_name}), state}

      error ->
        {error, state}
    end
  end

  defp do_unwatch(file_path, cleanup, state) do
    log_dir = Path.dirname(file_path)

    case Map.get(state, log_dir) do
      nil ->
        {:ok, state}

      pid ->
        file_name = Path.basename(file_path)

        case GenServer.call(pid, {:unwatch, file_name, cleanup}) do
          {:ok, :gone} ->
            {:ok, Map.delete(state, log_dir)}

          {:ok, _} ->
            {:ok, state}

          error ->
            {error, state}
        end
    end
  end

  defp find_or_add_watcher(session_id, log_dir, state) do
    case Map.get(state, log_dir) do
      nil ->
        case FileWatcher.start_link(session_id: session_id, log_dir: log_dir) do
          {:ok, pid} ->
            {{:ok, pid}, Map.put(state, log_dir, pid)}

          error ->
            {error, state}
        end

      pid ->
        {{:ok, pid}, state}
    end
  end

  defp remove_watcher(log_dir, state) do
    case Map.get(state, log_dir) do
      nil ->
        {:ok, state}

      pid ->
        GenServer.call(pid, :kill)
        {:ok, Map.delete(state, log_dir)}
    end
  end
end
