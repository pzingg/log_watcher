defmodule LogWatcher.FileWatcher do
  @moduledoc """
  A GenServer that monitors a directory, and can add individual files to be
  watched for modifications or closes.
  """
  use GenServer

  require Logger

  alias LogWatcher.Tasks.Session

  defmodule WatchedFile do
    @enforce_keys [:stream]

    defstruct stream: nil,
              position: 0,
              size: 0,
              last_modified: 0,
              start_sent: false

    @type t :: %__MODULE__{
            stream: File.Stream.t(),
            position: integer(),
            size: integer(),
            last_modified: integer(),
            start_sent: boolean()
          }

    def new(dir, file_name) do
      path = Path.join(dir, file_name)
      %__MODULE__{stream: File.stream!(path)}
    end
  end

  defimpl String.Chars, for: LogWatcher.FileWatcher.WatchedFile do
    def to_string(%WatchedFile{stream: stream, position: position, start_sent: start_sent}) do
      "%LogWatcher.FileWatcher.WatchedFile{stream: #{stream.path}, position: #{position}, start_sent: #{
        start_sent
      }}"
    end
  end

  @enforce_keys [:watcher_pid, :session_id, :session_log_path]

  defstruct watcher_pid: nil,
            session_id: nil,
            session_log_path: nil,
            files: %{}

  @type state :: %__MODULE__{
          watcher_pid: pid(),
          session_id: String.t(),
          session_log_path: String.t(),
          files: map()
        }

  @type gproc_key :: {:n, :l, {:session_id, String.t()}}

  @task_started_status ["running", "cancelled", "completed"]

  @task_completed_status ["cancelled", "completed"]

  @doc """
  Public interface. Subscribe to task messages, start the GenServer for a session,
  and watch a log file.
  """
  @spec start_link_and_watch_file(String.t(), String.t(), String.t()) :: :ok
  def start_link_and_watch_file(session_id, session_log_path, log_file) do
    with :ok <- Session.events_topic(session_id) |> Session.subscribe(),
         {:ok, _watcher_pid} <- start_or_find_link(session_id, session_log_path),
         {:ok, _file} <- add_watch(session_id, log_file) do
      :ok
    end
  end

  @spec start_or_find_link(String.t(), String.t()) :: GenServer.on_start()
  defp start_or_find_link(session_id, session_log_path) do
    case start_link(session_id, session_log_path) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      other ->
        other
    end
  end

  @doc """
  Public interface. Start the GenServer for a session.
  """
  @spec start_link(String.t(), String.t()) :: GenServer.on_start()
  def start_link(session_id, session_log_path) do
    Logger.info("start_link #{session_id} #{session_log_path}")
    GenServer.start_link(__MODULE__, [session_id, session_log_path], name: via_tuple(session_id))
  end

  @doc """
  Public interface. Sends a call to kill the GenServer.
  """
  @spec stop(String.t()) :: :ok
  def stop(session_id) do
    GenServer.call(via_tuple(session_id), :kill)
  end

  @doc """
  Public interface. Add a file to the watch list.
  """
  @spec add_watch(String.t(), String.t()) :: {:ok, String.t()}
  def add_watch(session_id, file_name) do
    Logger.info("add_watch #{session_id} #{file_name}")
    GenServer.call(via_tuple(session_id), {:add_watch, file_name})
  end

  @doc """
  Public interface. Remove a file from the watch list.
  """
  @spec remove_watch(String.t(), String.t()) :: {:ok, String.t()}
  def remove_watch(session_id, file_name) do
    GenServer.call(via_tuple(session_id), {:remove_watch, file_name})
  end

  @doc """
  Public interface. Return the :via tuple for this server.
  """
  @spec via_tuple(String.t()) :: {:via, :gproc, gproc_key()}
  def via_tuple(session_id) do
    {:via, :gproc, registry_key(session_id)}
  end

  @doc """
  Public interface. Return the pid for a server.
  """
  @spec registered(String.t()) :: pid() | :undefined
  def registered(session_id) do
    :gproc.where(registry_key(session_id))
  end

  @doc """
  Public interface. Return the key used to register a server.
  """
  @spec registry_key(String.t()) :: gproc_key()
  def registry_key(session_id) do
    {:n, :l, {:session_id, session_id}}
  end

  @doc """
  Init callback. Returns the initial state, but continues with a :check message.
  """
  @impl true
  @spec init(term()) :: {:ok, state()}
  def init([session_id, session_log_path]) do
    Logger.info("init #{session_id} #{session_log_path}")

    args = [dirs: [session_log_path], recursive: false]
    Logger.info("start FileSystem link with #{inspect(args)}")

    {:ok, watcher_pid} = FileSystem.start_link(args)
    FileSystem.subscribe(watcher_pid)

    initial_state = %__MODULE__{
      watcher_pid: watcher_pid,
      session_id: session_id,
      session_log_path: session_log_path
    }

    {:ok, initial_state}
  end

  # events: {#PID<0.319.0>,
  # "priv/mock_task/output/T10-create-003-log.jsonl",
  # [:created]}

  # events: {#PID<0.319.0>,
  # "priv/mock_task/output/T10-create-003-log.jsonl",
  # [:modified]}

  # events: {#PID<0.319.0>,
  # "priv/mock_task/output/T10-create-003-log.jsonl",
  # [:modified, :closed]}

  @doc """
  Handles :kill call. Checks for any final lines before stopping the genserver
  """
  @impl true
  def handle_call(:kill, _from, state) do
    next_state = check_all_files(state)
    {:stop, :normal, :ok, next_state}
  end

  @doc false
  def handle_call(
        {:add_watch, file_name},
        _from,
        %__MODULE__{session_id: session_id, session_log_path: session_log_path, files: files} =
          state
      ) do
    file = WatchedFile.new(session_log_path, file_name)
    {_lines, next_file} = check_for_lines(session_id, file)
    Logger.info("watch added for #{next_file}")
    next_state = %__MODULE__{state | files: Map.put_new(files, file_name, next_file)}
    {:reply, {:ok, file_name}, next_state}
  end

  @doc false
  def handle_call(
        {:remove_watch, file_name},
        _from,
        %__MODULE__{session_id: session_id, files: files} = state
      ) do
    next_state =
      case Map.get(files, file_name) do
        %WatchedFile{} = file ->
          _ = check_for_lines(session_id, file)
          %__MODULE__{state | files: Map.drop(files, file_name)}

        _ ->
          state
      end

    {:reply, {:ok, file_name}, next_state}
  end

  @impl true
  def handle_info(
        {:file_event, watcher_pid, {path, events}},
        %__MODULE__{watcher_pid: watcher_pid, session_id: session_id, files: files} = state
      ) do
    Logger.info("#{inspect(watcher_pid)} #{path}: #{inspect(events)}")

    file_name = Path.basename(path)

    case Map.get(files, file_name) do
      nil ->
        {:noreply, state}

      %WatchedFile{} = file ->
        {_lines, next_state} =
          if Enum.member?(events, :modified) do
            Logger.error("got :modified event for #{file_name}")
            {lines, next_file} = check_for_lines(session_id, file)
            {lines, %__MODULE__{state | files: Map.put(files, file_name, next_file)}}
          else
            {[], state}
          end

        if Enum.member?(events, :closed) do
          Logger.error("got :closed event for #{file_name}")
          handle_close(session_id, file_name)
          {:noreply, next_state}
        else
          {:noreply, next_state}
        end
    end
  end

  def handle_info(
        {:file_event, watcher_pid, :stop},
        %__MODULE__{watcher_pid: watcher_pid} = state
      ) do
    Logger.info("#{inspect(watcher_pid)} :stop")
    {:stop, :normal, state}
  end

  @spec check_all_files(state()) :: map()
  defp check_all_files(%__MODULE__{session_id: session_id, files: files}) do
    Enum.map(files, fn {file_name, file} ->
      {_lines, next_file} = check_for_lines(session_id, file)
      {file_name, next_file}
    end)
    |> Enum.into(%{})
  end

  @spec check_for_lines(String.t(), WatchedFile.t()) :: {[String.t()], WatchedFile.t()}
  defp check_for_lines(
         session_id,
         %WatchedFile{
           stream: stream,
           position: position,
           # last_modified: last_modified,
           size: size
         } = file
       ) do
    # Don't check change in :mtime! Things can happen fast!
    with {:exists, true} <- {:exists, File.exists?(stream.path)},
         {:ok, stat} <- File.stat(stream.path),
         # {:mtime, true} <- {:mtime, stat.mtime != last_modified},
         {:size, true} <- {:size, stat.size >= size} do
      lines =
        stream
        |> Stream.drop(position)
        |> Enum.into([])

      next_file = %WatchedFile{
        file
        | position: position + length(lines),
          size: stat.size,
          last_modified: stat.mtime
      }

      {lines, handle_lines(session_id, next_file, lines)}
    else
      {:exists, _} ->
        Logger.error("WatchedFile #{stream.path} does not exist")
        {[], %WatchedFile{file | stream: File.stream!(stream.path), position: 0, size: 0}}

      {:size, _} ->
        Logger.error("no increase in size")
        {[], %WatchedFile{file | stream: File.stream!(stream.path), position: 0, size: 0}}

      # {:mtime, _} ->
      #  Logger.error("no change in mtime")
      #  {[], file}

      {:error, reason} ->
        Logger.error("cannot stat #{stream.path}: #{inspect(reason)}")
        {[], %WatchedFile{file | stream: File.stream!(stream.path), position: 0, size: 0}}
    end
  end

  @spec handle_lines(String.t(), WatchedFile.t(), [String.t()]) :: boolean()
  defp handle_lines(_session_id, %WatchedFile{} = file, []), do: file

  defp handle_lines(session_id, %WatchedFile{stream: stream} = file, lines) do
    file_name = Path.basename(stream.path)

    Logger.info("file #{file_name} got #{Enum.count(lines)} lines")

    topic = Session.events_topic(session_id)

    Enum.reduce(lines, file, fn line, %WatchedFile{start_sent: start_sent} = acc ->
      %{status: status} = info = Jason.decode!(line, keys: :atoms)
      Logger.info("start_sent #{start_sent} status #{info[:status]}")

      next_acc =
        if !start_sent && Enum.member?(@task_started_status, status) do
          Session.broadcast(topic, {:task_started, file_name, info})
          %WatchedFile{acc | start_sent: true}
        else
          acc
        end

      Session.broadcast(topic, {:task_updated, file_name, info})

      if Enum.member?(@task_completed_status, status) do
        Session.broadcast(topic, {:task_completed, file_name})
      end

      next_acc
    end)
  end

  @spec handle_close(String.t(), String.t()) :: :ok
  defp handle_close(_session_id, file_name) do
    Logger.info("file #{file_name} closed")
    :ok
  end
end
