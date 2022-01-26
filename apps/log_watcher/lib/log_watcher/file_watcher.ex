defmodule LogWatcher.FileWatcher do
  @moduledoc """
  A GenServer that monitors a directory for file system changes,
  and broadcasts progress over Elixir PubSub. The directory, called
  the "log_dir" is identified by a "session_id" that defines
  the well-known PubSub topic, `session:session_id`.

  Once started, clients of the server add individual files to be
  watched for file modifications using the Elixir `FileSystem`
  module, which uses POSIX inotify tools.

  The files being watched are expected to produce output as JSON lines.

  An Elixir `File.Stream` is opened on each file being watched.
  If a file modification is detected, the server reads the new output
  from the stream, parses each JSON line, and broadcasts the parsed
  object on the PubSub session topic. A decoded line in the log file
  is expected to be an Elixir map that includes a `:status` item.
  The `:status` value is expected to be a string with one of these values:
  "initializing" "created", "reading", "validating", "running",
  "cancelled" or "completed". If the `:status` item is missing,
  it will be set to "undefined".

  A `:command_updated` message is sent for each line successfully parsed
  from the file being watched.

  A `:command_started` message is sent for the first line that has a
  status of "running", "cancelled" or "completed".

  A `:command_completed` message is sent for each line that has a status
  of "cancelled" or "completed", but this is expected to happen
  at most one time.

  The payload for each of these messages is the file name (without
  the path) that produced the change, and the map that was parsed,
  containing at a minimum the `:session_id` and `:status` items.
  """
  use GenServer

  require Logger

  alias LogWatcher.CommandStarter

  defmodule WatchedFile do
    @enforce_keys [:listener, :stream]

    defstruct listener: nil,
              stream: nil,
              position: 0,
              size: 0,
              last_modified: 0,
              start_sent: false

    @type t :: %__MODULE__{
            listener: pid(),
            stream: File.Stream.t(),
            position: integer(),
            size: integer(),
            last_modified: integer(),
            start_sent: boolean()
          }

    @doc """
    Construct a `LogWatcher.WatchedFile` struct for a directory and file name.
    """
    @spec new(String.t(), String.t(), pid()) :: t()
    def new(dir, file_name, listener) do
      path = Path.join(dir, file_name)
      %__MODULE__{listener: listener, stream: File.stream!(path)}
    end
  end

  defimpl String.Chars, for: LogWatcher.FileWatcher.WatchedFile do
    def to_string(%WatchedFile{stream: stream, position: position, start_sent: start_sent}) do
      "%LogWatcher.FileWatcher.WatchedFile{stream: #{stream.path}, position: #{position}, start_sent: #{start_sent}}"
    end
  end

  @enforce_keys [:fs_pid, :session_id, :log_dir]

  defstruct fs_pid: nil,
            session_id: nil,
            log_dir: nil,
            files: %{}

  @type state() :: %__MODULE__{
          fs_pid: pid(),
          session_id: String.t(),
          log_dir: String.t(),
          files: map()
        }

  @type gproc_key :: {:n, :l, {:session_id, String.t()}}

  @command_started_status ["running", "cancelled", "completed"]

  @command_completed_status ["cancelled", "completed"]

  @doc """
  Public interface. Start the GenServer for a session.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    log_dir = Keyword.fetch!(opts, :log_dir)
    _ = Logger.info("FileWatcher start_link #{session_id} #{log_dir}")
    GenServer.start_link(__MODULE__, [session_id, log_dir], name: via_tuple(session_id))
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
  @spec add_watch(String.t(), String.t(), pid()) :: {:ok, String.t()}
  def add_watch(session_id, file_name, listener) do
    _ = Logger.info("FileWatcher add_watch #{session_id} #{file_name}")
    GenServer.call(via_tuple(session_id), {:add_watch, file_name, listener})
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

  # Callbacks

  @doc false
  @impl true
  @spec init(term()) :: {:ok, state()}
  def init([session_id, log_dir]) do
    _ = Logger.info("FileWatcher init #{session_id} #{log_dir}")

    # Trap exits so we terminate if parent dies
    Process.flag(:trap_exit, true)

    args = [dirs: [log_dir], recursive: false]
    _ = Logger.info("FileWatcher start FileSystem link with #{inspect(args)}")

    {:ok, fs_pid} = FileSystem.start_link(args)
    FileSystem.subscribe(fs_pid)

    initial_state = %__MODULE__{
      fs_pid: fs_pid,
      session_id: session_id,
      log_dir: log_dir
    }

    {:ok, initial_state}
  end

  # events: {#PID<0.319.0>,
  # "priv/mock_command/output/T10-create-003-log.jsonl",
  # [:created]}

  # events: {#PID<0.319.0>,
  # "priv/mock_command/output/T10-create-003-log.jsonl",
  # [:modified]}

  # events: {#PID<0.319.0>,
  # "priv/mock_command/output/T10-create-003-log.jsonl",
  # [:modified, :closed]}

  @doc false
  @impl true
  @spec handle_call(term(), GenServer.from(), state()) ::
          {:reply, term(), state()} | {:stop, :normal, state()}
  def handle_call(:kill, _from, state) do
    # Handles :kill call.
    # Checks for any final lines before stopping the GenServer.
    next_state = check_all_files(state)
    {:stop, :normal, :ok, next_state}
  end

  def handle_call(
        {:add_watch, file_name, listener},
        _from,
        %__MODULE__{session_id: session_id, log_dir: log_dir, files: files} = state
      ) do
    file = WatchedFile.new(log_dir, file_name, listener)
    next_file = check_for_lines(session_id, file)
    _ = Logger.info("FileWatcher watch added for #{file_name}")
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

  @doc false
  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()} | {:stop, :normal, state()}
  def handle_info(
        {:file_event, fs_pid, {path, events}},
        %__MODULE__{fs_pid: fs_pid, session_id: session_id, files: files} = state
      ) do
    # Logger.info("FileWatcher #{inspect(fs_pid)} #{path}: #{inspect(events)}")

    file_name = Path.basename(path)

    case Map.get(files, file_name) do
      nil ->
        {:noreply, state}

      %WatchedFile{} = file ->
        next_state =
          if Enum.member?(events, :modified) do
            next_file = check_for_lines(session_id, file)
            %__MODULE__{state | files: Map.put(files, file_name, next_file)}
          else
            state
          end

        {:noreply, next_state}
    end
  end

  def handle_info(
        {:file_event, fs_pid, :stop},
        %__MODULE__{fs_pid: fs_pid} = state
      ) do
    _ = Logger.info("FileWatcher #{inspect(fs_pid)} :stop")
    {:stop, :normal, state}
  end

  @doc false
  @impl true
  def terminate(reason, _state) do
    _ = Logger.error("FileWatcher terminating #{inspect(reason)}")
  end

  # Private functions

  @spec check_all_files(state()) :: map()
  defp check_all_files(%__MODULE__{session_id: session_id, files: files}) do
    Enum.map(files, fn {file_name, file} ->
      next_file = check_for_lines(session_id, file)
      {file_name, next_file}
    end)
    |> Enum.into(%{})
  end

  @spec check_for_lines(String.t(), WatchedFile.t()) :: WatchedFile.t()
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

      handle_lines(session_id, next_file, lines)
    else
      {:exists, _} ->
        # Logger.error("FileWatcher #{stream.path} does not exist")
        %WatchedFile{file | stream: File.stream!(stream.path), position: 0, size: 0}

      {:size, _} ->
        _ = Logger.error("FileWatcher no increase in size")
        %WatchedFile{file | stream: File.stream!(stream.path), position: 0, size: 0}

      # {:mtime, _} ->
      #  Logger.error("FileWatcher no change in mtime")
      #  file

      {:error, reason} ->
        _ = Logger.error("FileWatcher cannot stat #{stream.path}: #{inspect(reason)}")
        %WatchedFile{file | stream: File.stream!(stream.path), position: 0, size: 0}
    end
  end

  @spec handle_lines(String.t(), WatchedFile.t(), [String.t()]) :: WatchedFile.t()
  defp handle_lines(_session_id, %WatchedFile{} = file, []), do: file

  defp handle_lines(session_id, %WatchedFile{stream: stream} = file, lines) do
    file_name = Path.basename(stream.path)

    _ = Logger.info("FileWatcher got #{Enum.count(lines)} line(s) from #{file_name}")

    Enum.reduce(lines, file, fn line, acc ->
      report_changes(session_id, file_name, line, acc)
    end)
  end

  @spec report_changes(String.t(), String.t(), String.t(), WatchedFile.t()) :: WatchedFile.t()
  defp report_changes(
         session_id,
         file_name,
         line,
         %WatchedFile{listener: listener, start_sent: start_sent} = file
       ) do
    case Jason.decode(line, keys: :atoms) do
      {:ok, data} when is_map(data) ->
        info =
          data
          |> Map.put_new(:session_id, session_id)
          |> Map.put_new(:status, "undefined")
          |> Map.put_new(:file_name, file_name)

        _ = CommandStarter.send_event(listener, :command_updated, info)

        # :command_started is only sent after we have validated.
        # It will cause the CommandStarter to exit the message loop and return.
        next_file =
          if !start_sent && Enum.member?(@command_started_status, info.status) do
            _ = CommandStarter.send_event(listener, :command_started, info)
            %WatchedFile{file | start_sent: true}
          else
            file
          end

        if Enum.member?(@command_completed_status, info.status) do
          _ = CommandStarter.send_event(listener, :command_completed, info)
        end

        next_file

      _ ->
        _ = Logger.error("FileWatcher, ignoring non-JSON: #{line}")
        file
    end
  end
end
