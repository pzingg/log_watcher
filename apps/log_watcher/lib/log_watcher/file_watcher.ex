defmodule LogWatcher.FileWatcher do
  @moduledoc """
  A GenServer that monitors a directory for file system changes.

  Once started, clients of the server add individual files to be
  watched for file modifications using the Elixir `FileSystem`
  module, which uses POSIX inotify tools.

  The files being watched are expected to produce output as JSON lines.

  An Elixir `File.Stream` is opened on each file being watched.
  If a file modification is detected, the server reads the new output
  from the stream, parses each JSON line, and broadcasts the parsed
  object on the PubSub session topic. A decoded line in the log file
  is expected to be an Elixir map that includes `:message`, `:status`
  and `:time` items.

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
  """
  use GenServer, restart: :transient

  require Logger

  alias LogWatcher.ScriptRunner

  defmodule WatchedFile do
    @moduledoc false

    @enforce_keys [:session_id, :command_id, :command_name, :file_name, :stream]

    defstruct session_id: nil,
              command_id: nil,
              command_name: nil,
              file_name: nil,
              stream: nil,
              position: 0,
              size: 0,
              last_modified: 0,
              start_sent: false

    @type t :: %__MODULE__{
            session_id: String.t(),
            command_id: String.t(),
            command_name: String.t(),
            file_name: String.t(),
            stream: File.Stream.t(),
            position: integer(),
            size: integer(),
            last_modified: integer(),
            start_sent: boolean()
          }

    @doc """
    Construct a `LogWatcher.WatchedFile` struct for a directory and file name.
    """
    @spec new(String.t(), String.t(), String.t(), String.t()) :: t()
    def new(session_id, command_id, command_name, path) do
      %__MODULE__{
        session_id: session_id,
        command_id: command_id,
        command_name: command_name,
        file_name: Path.basename(path),
        stream: File.stream!(path)
      }
    end
  end

  defimpl String.Chars, for: LogWatcher.FileWatcher.WatchedFile do
    def to_string(%WatchedFile{stream: stream, position: position, start_sent: start_sent}) do
      "%LogWatcher.FileWatcher.WatchedFile{stream: #{stream.path}, position: #{position}, start_sent: #{start_sent}}"
    end
  end

  @enforce_keys [:fs_pid, :log_dir]

  defstruct fs_pid: nil,
            log_dir: nil,
            in_cleanup: false,
            files: %{}

  @type state() :: %__MODULE__{
          fs_pid: pid(),
          log_dir: String.t(),
          in_cleanup: boolean(),
          files: map()
        }

  @type gproc_key :: {:n, :l, {:watch_dir, String.t()}}

  @command_started_status ["running", "cancelled", "completed"]

  @command_completed_status ["cancelled", "completed"]

  @doc """
  Public interface. Start the GenServer for a session.
  """
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(log_dir) when is_binary(log_dir) do
    GenServer.start_link(__MODULE__, log_dir, name: via_tuple(log_dir))
  end

  def start_link(_arg), do: {:error, :badarg}

  @doc false
  def kill(log_dir) do
    GenServer.call(via_tuple(log_dir), :kill)
  end

  @doc false
  def watch(log_dir, session_id, command_id, command_name, file_name) do
    GenServer.call(via_tuple(log_dir), {:watch, session_id, command_id, command_name, file_name})
  end

  @doc false
  def unwatch(log_dir, file_name, cleanup \\ false) do
    GenServer.call(via_tuple(log_dir), {:unwatch, file_name, cleanup})
  end

  @doc """
  Return the :via tuple for this server.
  """
  @spec via_tuple(String.t()) :: {:via, :gproc, gproc_key()}
  def via_tuple(log_dir) do
    {:via, :gproc, registry_key(log_dir)}
  end

  @doc """
  Return the pid for this server.
  """
  @spec whereis(pid() | String.t()) :: pid() | :undefined
  def whereis(pid) when is_pid(pid), do: pid

  def whereis(log_dir) when is_binary(log_dir) do
    :gproc.where(registry_key(log_dir))
  end

  # Callbacks

  @doc false
  @impl true
  @spec init(term()) :: {:ok, state()}
  def init(log_dir) do
    _ = Logger.debug("FileWatcher init #{log_dir}")

    # Trap exits so we terminate if parent dies
    _ = Process.flag(:trap_exit, true)

    args = [dirs: [log_dir], recursive: false]
    _ = Logger.debug("FileWatcher start FileSystem link with #{inspect(args)}")

    {:ok, fs_pid} = FileSystem.start_link(args)
    FileSystem.subscribe(fs_pid)

    initial_state = %__MODULE__{
      fs_pid: fs_pid,
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

  def handle_call({:watch, _, _, _}, _from, %__MODULE__{in_cleanup: true} = state) do
    {:reply, {:error, :in_cleanup}, state}
  end

  def handle_call(
        {:watch, session_id, command_id, command_name, file_name},
        _from,
        %__MODULE__{log_dir: log_dir, files: files} = state
      ) do
    if Map.get(files, file_name) do
      {:reply, {:error, :already_watching}, state}
    else
      file = WatchedFile.new(session_id, command_id, command_name, Path.join(log_dir, file_name))
      file = check_for_lines(file)
      _ = Logger.debug("FileWatcher watch added for #{file_name}")
      state = %__MODULE__{state | files: Map.put_new(files, file_name, file)}
      {:reply, :ok, state}
    end
  end

  def handle_call({:unwatch, _, _}, _from, %__MODULE__{in_cleanup: true} = state) do
    {:reply, {:error, :in_cleanup}, state}
  end

  def handle_call(
        {:unwatch, file_name, cleanup},
        _from,
        %__MODULE__{files: files} = state
      ) do
    {reply, state} =
      case Map.get(files, file_name) do
        nil ->
          {{:error, :not_found}, state}

        %WatchedFile{} = file ->
          _ = check_for_lines(file)
          files = Map.delete(files, file_name)

          if cleanup && Enum.empty?(files) do
            send(self(), :cleanup)
            {{:ok, :gone}, %__MODULE__{state | files: files, in_cleanup: true}}
          else
            {{:ok, :more}, %__MODULE__{state | files: files}}
          end
      end

    {:reply, reply, state}
  end

  @doc false
  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()} | {:stop, :normal, state()}
  def handle_info(
        {:file_event, fs_pid, {path, events}},
        %__MODULE__{fs_pid: fs_pid, files: files} = state
      ) do
    # Logger.debug("FileWatcher #{inspect(fs_pid)} #{path}: #{inspect(events)}")

    file_name = Path.basename(path)

    case Map.get(files, file_name) do
      nil ->
        {:noreply, state}

      %WatchedFile{} = file ->
        next_state =
          if Enum.member?(events, :modified) do
            next_file = check_for_lines(file)
            %__MODULE__{state | files: Map.put(files, file_name, next_file)}
          else
            state
          end

        {:noreply, next_state}
    end
  end

  def handle_info(
        {:file_event, fs_pid, :stop},
        %__MODULE__{log_dir: log_dir, fs_pid: fs_pid} = state
      ) do
    _ = Logger.debug("FileWatcher #{String.slice(log_dir, -20..-1)} :file_event :stop => :stop")
    {:stop, :normal, state}
  end

  def handle_info(:cleanup, %__MODULE__{log_dir: log_dir} = state) do
    _ = Logger.debug("FileWatcher #{String.slice(log_dir, -20..-1)} cleanup => :stop")
    {:stop, :normal, state}
  end

  def handle_info(unexpected, %__MODULE__{log_dir: log_dir} = state) do
    _ =
      Logger.debug(
        "FileWatcher #{String.slice(log_dir, -20..-1)} unexpected #{inspect(unexpected)} => :stop"
      )

    {:stop, :normal, state}
  end

  @doc false
  @impl true
  def terminate(reason, %__MODULE__{log_dir: log_dir}) do
    _ = Logger.debug("FileWatcher #{String.slice(log_dir, -20..-1)} terminate #{reason}")
  end

  # Private functions

  @spec registry_key(String.t()) :: gproc_key()
  defp registry_key(log_dir) do
    {:n, :l, {:watch_dir, log_dir}}
  end

  @spec check_all_files(state()) :: map()
  defp check_all_files(%__MODULE__{files: files}) do
    Enum.map(files, fn {file_name, file} ->
      next_file = check_for_lines(file)
      {file_name, next_file}
    end)
    |> Enum.into(%{})
  end

  @spec check_for_lines(WatchedFile.t()) :: WatchedFile.t()
  defp check_for_lines(
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

      handle_lines(next_file, lines)
    else
      {:exists, _} ->
        # Logger.debug("FileWatcher #{stream.path} does not exist")
        %WatchedFile{file | stream: File.stream!(stream.path), position: 0, size: 0}

      {:size, _} ->
        _ = Logger.debug("FileWatcher no increase in size")
        %WatchedFile{file | stream: File.stream!(stream.path), position: 0, size: 0}

      # {:mtime, _} ->
      #  _ = Logger.debug("FileWatcher no change in mtime")
      #  file

      {:error, reason} ->
        _ = Logger.debug("FileWatcher cannot stat #{stream.path}: #{inspect(reason)}")
        %WatchedFile{file | stream: File.stream!(stream.path), position: 0, size: 0}
    end
  end

  @spec handle_lines(WatchedFile.t(), [String.t()]) :: WatchedFile.t()
  defp handle_lines(%WatchedFile{} = file, []), do: file

  defp handle_lines(%WatchedFile{file_name: file_name} = file, lines) do
    _ = Logger.debug("FileWatcher got #{Enum.count(lines)} line(s) from #{file_name}")

    Enum.reduce(lines, file, fn line, acc ->
      report_changes(line, acc)
    end)
  end

  @spec report_changes(String.t(), WatchedFile.t()) :: WatchedFile.t()
  defp report_changes(
         line,
         %WatchedFile{
           session_id: session_id,
           command_id: command_id,
           command_name: command_name,
           file_name: file_name,
           start_sent: start_sent
         } = file
       ) do
    case Jason.decode(line, keys: :atoms) do
      {:ok, event_data} when is_map(event_data) ->
        # Prefill all the required values
        event_data =
          event_data
          |> Map.put_new(:session_id, session_id)
          |> Map.put_new(:command_id, command_id)
          |> Map.put_new(:command_name, command_name)
          |> Map.put_new(:status, "undefined")
          |> Map.put_new(:file_name, file_name)

        _ = ScriptRunner.send_event(command_id, :command_updated, event_data)

        cond do
          Enum.member?(@command_completed_status, event_data.status) ->
            # Early completion (error in "reading" phase, e.g.)
            _ = ScriptRunner.send_event(command_id, :command_result, event_data)
            %WatchedFile{file | start_sent: true}

          !start_sent && Enum.member?(@command_started_status, event_data.status) ->
            # :command_started is only sent after we have validated.
            # It will cause the ScriptRunner to exit the message loop and return.
            _ = ScriptRunner.send_event(command_id, :command_started, event_data)
            %WatchedFile{file | start_sent: true}

          true ->
            file
        end

      _ ->
        _ = Logger.debug("FileWatcher, ignoring non-JSON: #{line}")
        file
    end
  end
end
