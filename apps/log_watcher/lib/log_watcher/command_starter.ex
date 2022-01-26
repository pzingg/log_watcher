defmodule LogWatcher.CommandStarter do
  @moduledoc """
  The module is responsible for
  setting up a monitoring system for long-running POSIX shell scripts
  that operate in a pre-defined directory on the file system.
  The scripts conform to a defined protocol for reading input
  from an arguments file and producing progress and result output
  in log files. The arguments file and log files have well-known names.

  As scripts run and produce output, progress log files are monitored
  by a separate process, the `LogWatcher.FileWatcher`.

  Scripts are launched and signaled through a third process, the
  `LogWatcher.ScriptServer`.
  """
  require Logger

  alias LogWatcher.{Commands, FileWatcherSupervisor, ScriptServer}
  alias LogWatcher.Sessions.Session
  alias LogWatcher.Commands.Command

  defmodule LoopInfo do
    @enforce_keys [:job_id, :command_id, :task_ref, :file_name, :cancel, :script_timeout]

    defstruct [
      :job_id,
      :command_id,
      :task_ref,
      :file_name,
      :cancel,
      :script_timeout,
      expiry: 0,
      sent_os_pid: false
    ]

    @type t() :: %__MODULE__{
            job_id: integer(),
            command_id: String.t(),
            task_ref: reference(),
            file_name: String.t(),
            cancel: String.t(),
            script_timeout: integer(),
            expiry: integer(),
            sent_os_pid: boolean()
          }
  end

  defdelegate cancel(key), to: ScriptServer
  defdelegate kill(key), to: ScriptServer
  defdelegate await(key, timeout), to: ScriptServer

  @default_script_timeout 120_000

  @doc """
  Start the file watcher, run the script, and receive messages.
  Note: command_args must have string keys!
  """
  @spec watch_and_run(Session.t(), String.t(), String.t(), map()) ::
          {:ok, term()} | {:discard, term()}
  def watch_and_run(session, command_id, command_name, command_args) do
    loop_info = start_watcher_and_script(session, command_id, command_name, command_args)
    run_loop(loop_info)
  end

  @doc """
  Just start the file watcher and run the script, but don't receive any messages.
  Used for observing the supervision tree.
  """
  @spec start_watcher_and_script(Session.t(), String.t(), String.t(), map()) :: LoopInfo.t()
  def start_watcher_and_script(
        %Session{id: session_id, log_dir: log_dir, gen: gen},
        command_id,
        command_name,
        command_args
      ) do
    _ = Logger.error("watch_and_run")

    log_file = Command.log_file_name(session_id, gen, command_id, command_name)
    script_file = Map.fetch!(command_args, "script_file")

    # Set up to receive messages
    job_id = Map.get(command_args, "oban_job_id", 0)
    cancel = Map.get(command_args, "cancel", "none")
    script_timeout = Map.get(command_args, "script_timeout", @default_script_timeout)

    # "sandbox_owner" not used, we're running tests with async: false
    # {sandbox_owner, command_args} = Map.pop(command_args, "sandbox_owner")

    _ =
      Logger.info(
        "command #{command_id}: job_id #{job_id}, cancel #{cancel}, pid is #{inspect(self())}"
      )

    _ = Logger.info("command #{command_id}: start watching #{log_file} in #{log_dir}")

    {:ok, watcher_pid, file_name} =
      FileWatcherSupervisor.start_child_and_watch_file(session_id, log_dir, log_file)

    _ = Logger.info("command #{command_id}: watcher is #{inspect(watcher_pid)}")

    # Write arg file
    start_args =
      Map.merge(command_args, %{
        "session_id" => session_id,
        "log_dir" => log_dir,
        "gen" => gen,
        "command_id" => command_id,
        "command_name" => command_name
      })
      |> Map.put_new("num_lines", 10)
      |> json_encode_decode(:atoms)

    arg_path =
      Path.join(log_dir, Command.arg_file_name(session_id, gen, command_id, command_name))

    _ = Logger.info("command #{command_id}: write arg file to #{arg_path}")

    :ok = Commands.write_arg_file(arg_path, start_args)

    # Start mock command script
    script_path = Path.join([:code.priv_dir(:log_watcher), "mock_command", script_file])
    _ = Logger.info("command #{command_id}: run script at #{script_path}")

    task_ref = ScriptServer.run_script(script_path, start_args, self())

    _ = Logger.info("command #{command_id}: script task ref is #{inspect(task_ref)}")

    %LoopInfo{
      job_id: job_id,
      command_id: command_id,
      task_ref: task_ref,
      file_name: file_name,
      cancel: cancel,
      script_timeout: script_timeout
    }
  end

  @doc """
  Process incoming messages to find a result.
  """
  @spec run_loop(LoopInfo.t()) :: {:ok, term()} | {:discard, term()}
  def run_loop(%LoopInfo{command_id: command_id, script_timeout: timeout} = info) do
    _ = Logger.error("command #{command_id}: starting loop")

    result = loop(%LoopInfo{info | expiry: System.monotonic_time(:millisecond) + timeout})
    # discard_remaining_messages()

    # Return disposition for Oban
    _ = Logger.error("command #{command_id}: exited loop, result is #{inspect(result)}")

    # Oban.Worker.perform return values:
    # :ok or {:ok, value} — the job is successful; for success tuples the
    #    value is ignored
    # :discard or {:discard, reason} — discard the job and prevent it from
    #    being retried again. An error is recorded using the optional reason,
    #    though the job is still successful
    # {:error, error} — the job failed, record the error and schedule a retry
    #    if possible
    # {:snooze, seconds} — mark the job as snoozed and schedule it to run
    #    again seconds in the future.
    case result do
      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:error, reason} ->
        {:discard, reason}
    end
  end

  @spec loop(LoopInfo.t()) ::
          {:ok, map()}
          | {:error,
             {:EXIT, pid(), atom()}
             | {:script_terminated, term()}
             | {:script_crashed, term()}
             | :timeout}
  @doc """
  Wait for messages from the log watching process.

  Returns `{:ok, result}` if the command entered the running phase without errors.
  The `result` is a map that contains information about the command,
  and `result.task_ref` is a reference to the Elixir Task that is running the
  command.

  Returns `{:error, {:EXIT, pid, reason}}` if our process was sent an
  abnormal exit message.

  Returns `{:error, {:script_error, exit_status}}` if the shell script called
  by the Elixir Command exited with a non-zero exit status, before it
  entered the start phase.

  Returns `{:error, :script_terminated}` or `
  {:error, {:script_terminated, reason}}` if the Elixir Command ended
  normally before it entered the running phase. `reason` is the value returned
  by the Command.

  Returns `{:error, {:script_crashed, reason}}` if the Elixir Command ended
  abnormally before it entered the running phase. `reason` is the value returned
  by the Command.

  Returns `{:error, :timeout}` if the script received neither a message
  with status "running" nor a termination message before the timeout period.
  """
  def loop(
        %LoopInfo{
          expiry: expiry,
          command_id: command_id,
          task_ref: task_ref
        } = info
      ) do
    time_now = System.monotonic_time(:millisecond)
    time_left = max(0, expiry - time_now)

    receive do
      {:command_event, event} ->
        process_command_event(event, info)

      {^task_ref, result} ->
        _ =
          Logger.error(
            "command #{command_id}, loop received command result for #{inspect(task_ref)}"
          )

        _ = Logger.info("command #{command_id}, loop returning :script_terminated")
        {:error, {:script_terminated, result}}

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        _ = Logger.error("command #{command_id}, loop received :DOWN")
        _ = Logger.info("command #{command_id}, loop returning :script_crashed")
        _info = Map.put(info, :task_ref, nil)
        {:error, {:script_crashed, reason}}

      {:EXIT, pid, reason} ->
        _ = Logger.error("command #{command_id}, loop received :EXIT #{reason}")
        _ = ScriptServer.cancel(task_ref)
        {:error, {:EXIT, pid, reason}}

      other ->
        _ = Logger.error("command #{command_id}, loop received #{inspect(other)}")
        {:error, :unimplemented}
    after
      time_left ->
        _ = Logger.error("command #{command_id}: loop timed out")
        {:error, :timeout}
    end
  end

  @doc """
  Convenience method to send an Elixir message to the CommandStarter process if
  it still alive, and posting it to the Broadway pipeline.
  """
  @spec send_event(pid(), atom(), map()) :: :ok
  def send_event(listener, event_type, data) do
    event = Map.put(data, :event_type, event_type)

    if Process.alive?(listener) do
      send(listener, {:command_event, event})
    end

    _ = LogWatcher.Pipeline.Handler.sync_notify(event)
  end

  defp process_command_event(
         %{event_type: event_type} = event,
         %LoopInfo{
           command_id: command_id,
           file_name: file_name
         } = info
       ) do
    _ = Logger.info("command #{command_id}, loop received #{event_type} on #{file_name}")

    info =
      case event_type do
        :command_updated ->
          info
          |> maybe_update_os_pid(event)
          |> maybe_cancel(event)

        :script_terminated ->
          Map.put(info, :task_ref, nil)

        _ ->
          info
      end

    case event_type do
      :command_started ->
        {:ok, Map.put(event, :task_ref, info.task_ref)}

      :script_terminated ->
        _ = Logger.error("command #{command_id}, loop returning :ok #{inspect(event)}")
        {:ok, Map.put(event, :task_ref, nil)}

      _ ->
        loop(info)
    end
  end

  @doc """
  Borrowed from Oban.Testing.
  Converts all atomic keys to strings, and verifies
  that args are JSON-encodable.
  """
  @spec json_encode_decode(map(), atom()) :: map()
  def json_encode_decode(map, key_type) do
    map
    |> Jason.encode!()
    |> Jason.decode!(keys: key_type)
  end

  @spec maybe_update_os_pid(LoopInfo.t(), map()) :: LoopInfo.t()
  defp maybe_update_os_pid(
         %LoopInfo{task_ref: task_ref, sent_os_pid: sent_os_pid} = info,
         event
       ) do
    os_pid = Map.get(event, :os_pid, 0)

    if os_pid != 0 && !sent_os_pid do
      _ = ScriptServer.update_os_pid(task_ref, os_pid)
      %LoopInfo{info | sent_os_pid: true}
    else
      info
    end
  end

  @spec maybe_cancel(LoopInfo.t(), map()) :: LoopInfo.t()
  defp maybe_cancel(
         %LoopInfo{command_id: command_id, task_ref: task_ref, cancel: cancel} = info,
         %{status: status}
       ) do
    if status == cancel do
      _ = Logger.error("command #{command_id}: cancelling script, last status read was #{status}")
      _ = ScriptServer.cancel(task_ref)
      %LoopInfo{info | cancel: "sent"}
    else
      info
    end
  end

  def to_pid(str) when is_binary(str), do: String.to_charlist(str) |> :erlang.list_to_pid()
  def to_pid(_), do: nil
end
