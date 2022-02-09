defmodule LogWatcher.ScriptRunner do
  @moduledoc """
  A GenServer that runs an OS shell script as a long-running Elixir
  Task. Before starting the task, the arguments that the script
  will use is written to a JSON-formatted file in the `log_dir`
  for the script, and a FileWatcher is set to watch for changes
  in a (JSONL-formatted) log file that the script will write to.

  The well-known names of the arg file and the log file are made
  by concatenating `session_id`, `gen`, `command_name` and
  `command_id` strings.

  If `await_running` is `true`, the `run_script` method will return
  a reply when the script has "started" (or failed to start),
  meaning that the OS shell, process has been created, the script
  has read any arguments and validated them, and has appended a
  log line with a status value of "running", "cancelled" or "completed".

  See the FileWatcher module documentation for more
  information on expectations for log file output.
  """
  use GenServer, restart: :transient

  require Logger

  alias LogWatcher.Commands
  alias LogWatcher.Commands.Command
  alias LogWatcher.FileWatcherManager

  defstruct session_id: nil,
            command_args: %{},
            log_dir: nil,
            gen: nil,
            command_id: nil,
            command_name: nil,
            script_path: nil,
            cancel: "",
            job_id: 0,
            os_pid: 0,
            last_update: %{},
            await_running: false,
            sigint_pending: false,
            task: nil,
            result: nil,
            client_from: nil,
            other_waiters: []

  @type state() :: %__MODULE__{
          command_args: map(),
          session_id: String.t(),
          log_dir: String.t(),
          gen: integer(),
          command_id: String.t(),
          command_name: String.t(),
          script_path: String.t(),
          cancel: String.t(),
          job_id: integer(),
          os_pid: integer(),
          last_update: map(),
          await_running: boolean(),
          sigint_pending: boolean(),
          task: Task.t() | nil,
          result: term(),
          client_from: GenServer.from() | nil,
          other_waiters: [{:atom, GenServer.from()}]
        }

  @type gproc_key :: {:n, :l, {:command_id, String.t()}}

  @event_data_keys [
    :session_id,
    :log_dir,
    :command_id,
    :command_name,
    :gen
  ]

  # Public interface

  @doc """
  Sets up a process to run a script. The argument is a map with
  these items:

  * `:session` - a Session struct (or map with at least `:id`,
    `:log_dir`, and `gen` members)
  * `:command_id`
  * `:command_name`
  * `:command_args` - a map of arguments that are passed to
    the OS shell, that must include a `:script_path` item that
    gives the full path to the .R or .py script to be
    executed.
  """
  def start_link(%{command_id: command_id} = arg) do
    GenServer.start_link(__MODULE__, arg, name: via_tuple(command_id))
  end

  def start_link(_arg), do: {:error, :badarg}

  @doc """
  Prepares the FileWatcher and runs the script (an .R or .py file) as
  an Elixir Task. The process will then receive events from the FileWatcher
  to update its state.
  """
  def run_script(command_id, await_running, timeout) do
    GenServer.call(via_tuple(command_id), {:run_script, await_running, timeout}, timeout + 100)
  end

  @doc """
  Returns `{:ok, :command_exit}` when the Elixir Task has completed, or
  `{:error, timeout}` if the timeout (in milliseconds) has been exceeded.
  """
  def await_exit(command_id, timeout) when is_integer(timeout) do
    GenServer.call(via_tuple(command_id), {:await, :command_exit, timeout}, timeout + 100)
  end

  @doc """
  Sends an OS SIGINT signal to the shell process. The .R or .py script is
  expected to clean up and exit on receipt of the SIGINT.
  """
  def cancel(command_id) do
    GenServer.call(via_tuple(command_id), :cancel)
  end

  @doc """
  Stops monitoring the long-running task as
  """
  def kill(command_id) do
    GenServer.call(via_tuple(command_id), :kill)
  end

  @doc """
  Convenience method to send an Elixir message to the ScriptRunner process if
  it still alive, and posting it to the Broadway pipeline.
  """
  @spec send_event(String.t(), atom(), map()) :: :ok
  def send_event(command_id, event_type, event_data) do
    event = Map.put(event_data, :event_type, event_type)

    case whereis(command_id) do
      :undefined ->
        :undefined

      pid ->
        if Process.alive?(pid) do
          send(pid, {:command_event, event})
        end
    end

    _ = LogWatcher.Pipeline.Handler.sync_notify(event)
  end

  @doc """
  Return the :via tuple for this server.
  """
  @spec via_tuple(String.t()) :: {:via, :gproc, gproc_key()}
  def via_tuple(command_id) do
    {:via, :gproc, registry_key(command_id)}
  end

  @doc """
  Return the pid for this server.
  """
  @spec whereis(pid() | String.t()) :: pid() | :undefined
  def whereis(pid) when is_pid(pid), do: pid

  def whereis(command_id) when is_binary(command_id) do
    :gproc.where(registry_key(command_id))
  end

  # Callbacks

  @doc false
  @impl true
  def init(%{
        session: session,
        command_id: command_id,
        command_name: command_name,
        command_args: command_args
      }) do
    # Trap exits so we terminate if parent dies
    _ = Process.flag(:trap_exit, true)

    log_dir = session.log_dir
    script_path = Map.get(command_args, :script_path)

    case check_access(script_path, log_dir) do
      :ok ->
        state = %__MODULE__{
          command_args: command_args,
          session_id: session.id,
          log_dir: log_dir,
          gen: session.gen,
          command_id: command_id,
          command_name: command_name,
          job_id: Map.get(command_args, :oban_job_id, 0),
          cancel: Map.get(command_args, :cancel, ""),
          script_path: script_path
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def init(_arg), do: {:error, :badarg}

  @doc false
  @impl true
  def handle_call(
        {:run_script, await_running, timeout},
        from,
        %__MODULE__{
          session_id: session_id,
          command_id: command_id,
          command_name: command_name,
          client_from: nil
        } = state
      ) do
    start_args = encode_start_args(state)
    _ = write_start_args(state, start_args)

    log_path = get_log_path(state)
    FileWatcherManager.watch(session_id, command_id, command_name, log_path)

    send(self(), {:await, :run_script, timeout})
    send(self(), :start_script_task)

    # If await_running is set, we will return the reply only after the script has
    # has entered the "running" state, or has terminated.
    {:noreply, %__MODULE__{state | client_from: from, await_running: await_running}}
  end

  def handle_call({:run_script, _await_running}, _from, state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call({:await, wait_type, timeout}, from, state) do
    state = set_timeout(state, wait_type, timeout, from)
    {:noreply, state}
  end

  def handle_call(:cancel, _from, state) do
    {reply, state} = do_cancel(state)
    {:reply, reply, state}
  end

  def handle_call(:kill, _from, %__MODULE__{command_id: command_id} = state) do
    _ = Logger.debug("ScriptRunner #{command_id} kill requested => stop")

    {_reply, state} =
      state
      |> maybe_send_reply(
        {:error, :kill_requested},
        fail_silently: true,
        log_message: "kill requested"
      )
      |> reply_to_all_waiters(:kill_requested)
      |> shutdown_and_remove_task()

    {:stop, :normal, :ok, state}
  end

  @doc false
  @impl true
  def handle_info(
        :start_script_task,
        %__MODULE__{command_id: command_id} = state
      ) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(LogWatcher.TaskSupervisor, fn ->
        do_run_script(parent, state)
      end)

    send(LogWatcher.CommandManager, {:task_started, command_id, task})

    # After we start the task, we store its reference and pid
    # If `await_running` is `false`, The `do_run_script` will send
    # an event to the `client_from` client when the shell script
    # is launched.
    {:noreply, %__MODULE__{state | task: task}}
  end

  def handle_info({:await, :run_script, timeout}, state) do
    state = set_timeout(state, :run_script, timeout)
    {:noreply, state}
  end

  def handle_info({:timeout, :run_script, _from}, state) do
    # Send timeout error event to run_script client
    state = maybe_send_reply(state, {:error, :timeout}, log_message: "timeout")
    {:noreply, state}
  end

  def handle_info(
        {:timeout, wait_type, from},
        %__MODULE__{other_waiters: waiters} = state
      ) do
    # Send error, :timeout reply
    GenServer.reply(from, {:error, :timeout})
    {:noreply, %__MODULE__{state | other_waiters: List.delete(waiters, {wait_type, from})}}
  end

  def handle_info({:command_event, event}, state) do
    handle_command_event(event, state)
  end

  def handle_info(
        {result_ref, result},
        %__MODULE__{command_id: command_id, task: task} = state
      )
      when is_reference(result_ref) do
    message =
      if !is_nil(task) && result_ref == task.ref do
        "command result"
      else
        "other ref result"
      end

    _ = Logger.debug("ScriptRunner #{command_id} received #{message}")

    state =
      state
      |> maybe_send_reply({:error, {:command_result, result}}, log_message: message)

    {:noreply, %__MODULE__{state | result: result}}
  end

  def handle_info(
        {:DOWN, down_ref, :process, _pid, reason},
        %__MODULE__{command_id: command_id, task: task} = state
      ) do
    {state, message} =
      if !is_nil(task) && down_ref == task.ref do
        {%__MODULE__{state | task: nil}, "task DOWN #{reason}"}
      else
        {state, "other ref DOWN #{reason}"}
      end

    _ = Logger.debug("ScriptRunner #{command_id} received #{message}")

    # Will only send this if :command_result was never sent.
    state
    |> maybe_send_reply({:error, {:command_exit, reason}},
      log_message: message
    )
    |> reply_to_all_waiters(:command_exit)

    {:noreply, state}
  end

  # Cancel message sends interrupt, we get this.
  def handle_info(
        {:EXIT, _port, reason},
        %__MODULE__{command_id: command_id} = state
      ) do
    _ = Logger.debug("ScriptRunner #{command_id} received port EXIT #{reason}")

    # Will only send this if :command_result was never sent.
    state =
      state
      |> maybe_send_reply({:error, {:command_exit, reason}},
        log_message: "port EXIT #{reason}"
      )
      |> reply_to_all_waiters(:command_exit)

    {:noreply, state}
  end

  def handle_info(unexpected, %__MODULE__{command_id: command_id} = state) do
    _ = Logger.debug("ScriptRunner #{command_id} unexpected #{inspect(unexpected)}")

    state =
      maybe_send_reply(state, {:error, :unimplemented},
        log_message: "unexpected: #{inspect(unexpected)}"
      )

    # Maybe return {:stop, :normal, state}?
    {:noreply, state}
  end

  @doc false
  @impl true
  def terminate(reason, %__MODULE__{command_id: command_id} = state) do
    _ = Logger.error("ScriptRunner #{command_id} terminate #{reason}")
    log_path = get_log_path(state)
    FileWatcherManager.unwatch(log_path, true)

    :ok
  end

  # Private functions

  defp set_timeout(%__MODULE__{other_waiters: waiters} = state, wait_type, timeout, from \\ nil) do
    Process.send_after(self(), {:timeout, wait_type, from}, timeout)

    if wait_type != :run_script do
      %__MODULE__{state | other_waiters: [{wait_type, from} | waiters]}
    else
      state
    end
  end

  defp reply_to_all_waiters(
         %__MODULE__{other_waiters: waiters, result: result} = state,
         wait_type
       ) do
    # If anyone else was waiting.
    # TODO match the original wait_type if it's not :command_exit
    # Right now we only get called from `await_exit`, so this is OK.
    for {_wait_type, from} <- waiters do
      reply =
        if wait_type == :command_exit and !is_nil(result) do
          # result should be a tuple {:ok, ...} or {:error, ...}
          result
        else
          :ok
        end

      GenServer.reply(from, reply)
    end

    %__MODULE__{state | other_waiters: []}
  end

  @spec registry_key(String.t()) :: gproc_key()
  defp registry_key(command_id) do
    {:n, :l, {:command_id, command_id}}
  end

  defp check_access(script_path, log_dir) do
    with {:ok, _stat} <- File.stat(script_path),
         :ok <- File.mkdir_p(log_dir) do
      :ok
    else
      error -> error
    end
  end

  defp encode_start_args(%__MODULE__{
         command_id: command_id,
         command_name: command_name,
         session_id: session_id,
         log_dir: log_dir,
         gen: gen,
         command_args: command_args
       }) do
    command_args
    |> LogWatcher.json_encode_decode(:atoms)
    |> Map.merge(%{
      command_id: command_id,
      command_name: command_name,
      session_id: session_id,
      log_dir: log_dir,
      gen: gen
    })
    |> Map.put_new(:num_lines, 10)
  end

  defp write_start_args(%__MODULE__{command_id: command_id} = state, start_args) do
    arg_path = get_arg_path(state)

    _ = Logger.debug("ScriptRunner #{command_id}: write arg file to #{arg_path}")

    Commands.write_arg_file(arg_path, start_args)
  end

  defp get_arg_path(%__MODULE__{
         command_id: command_id,
         command_name: command_name,
         session_id: session_id,
         log_dir: log_dir,
         gen: gen
       }) do
    Path.join(log_dir, Command.arg_file_name(session_id, gen, command_id, command_name))
  end

  defp get_log_path(%__MODULE__{
         command_id: command_id,
         command_name: command_name,
         session_id: session_id,
         log_dir: log_dir,
         gen: gen
       }) do
    Path.join(log_dir, Command.log_file_name(session_id, gen, command_id, command_name))
  end

  # Task function, runs in its own proccess.
  # The `parent` argument is the ScriptRunner process that spawned this process.
  @spec do_run_script(pid(), state()) ::
          {:ok, map()} | {:error, term()}
  defp do_run_script(
         parent,
         %__MODULE__{
           command_id: command_id,
           command_name: command_name,
           session_id: session_id,
           log_dir: log_dir,
           gen: gen,
           script_path: script_path,
           command_args: script_args
         } = state
       ) do
    _ =
      _ =
      Logger.debug(
        "ScriptRunner #{command_id} run_script #{script_path} with #{inspect(script_args)}"
      )

    base_data =
      script_args
      |> Map.merge(Map.from_struct(state))
      |> Enum.filter(fn {key, _value} -> Enum.member?(@event_data_keys, key) end)
      |> Map.new()

    shell_command =
      case Path.extname(script_path) do
        ".R" -> "Rscript"
        ".py" -> "python3"
        _ -> "bash"
      end

    executable = System.find_executable(shell_command)

    if is_nil(executable) do
      event_data =
        base_data
        |> Map.merge(%{
          message: "no executable for #{Path.basename(script_path)}",
          status: "completed",
          errors: [
            %{
              message: "could not find executable #{shell_command}",
              category: "shell",
              system: true,
              fatal: true
            }
          ],
          time: LogWatcher.now()
        })

      _ = send_event(parent, :command_invalid, event_data)

      {:error, event_data}
    else
      shell_args =
        [
          "--log-dir",
          log_dir,
          "--session-id",
          session_id,
          "--command-id",
          command_id,
          "--command-name",
          command_name,
          "--gen",
          to_string(gen)
        ] ++ optional_args(script_args, [:error, :cancel])

      _ =
        _ =
        Logger.debug(
          "ScriptRunner #{command_id} shelling out to #{executable} with args #{inspect(shell_args)}"
        )

      event_data =
        base_data
        |> Map.merge(%{
          message: "Launching #{shell_command} for #{Path.basename(script_path)}",
          status: "initializing",
          time: LogWatcher.now()
        })

      # If `await_running` is false, this should send a reply back
      # to the `client_from` CommandManager.
      _ = send_event(parent, :command_launching, event_data)

      {output, exit_status} =
        System.cmd(executable, [script_path | shell_args], cd: Path.dirname(script_path))

      _ = Logger.error("ScriptRunner #{command_id} script exited with #{exit_status}")
      _ = Logger.debug("ScriptRunner #{command_id} output from script: #{inspect(output)}")

      errors =
        if exit_status == 0 do
          %{message: "script exited normally"}
        else
          %{
            message: "script exited with status #{exit_status}",
            errors: [
              %{
                message: "#{shell_command} exited with non-zero status",
                category: "shell",
                system: true,
                fatal: true
              }
            ]
          }
        end

      event_data =
        base_data
        |> Map.merge(%{
          status: "completed",
          exit_status: exit_status,
          time: LogWatcher.now()
        })
        |> Map.merge(errors)
        |> parse_result(output)

      _ = send_event(parent, :command_result, event_data)

      {:ok, event_data}
    end
  end

  defp optional_args(script_args, keys) do
    Enum.reduce(keys, [], fn key, acc ->
      value = Map.get(script_args, key)

      if is_binary(value) && value != "" do
        acc ++ ["--#{key}", value]
      else
        acc
      end
    end)
  end

  @pre_running_event_types [:command_launching, :command_updated]

  defp handle_command_event(
         %{event_type: event_type} = event,
         %__MODULE__{command_id: command_id, task: task, await_running: await_running} = state
       ) do
    _ = Logger.debug("ScriptRunner #{command_id} received #{event_type}")

    # Include task information in event
    event = add_task_info(event, task)

    state =
      if event_type == :command_updated do
        state
        |> maybe_update_os_pid(event)
        |> maybe_cancel()
      else
        state
      end

    state =
      if await_running && Enum.member?(@pre_running_event_types, event_type) do
        # Don't send a reply if we have not entered running state
        state
      else
        # If `event_type` is something else (`:command_started` or `:command_result`)
        # send it back to the client (CommandManager).
        maybe_send_reply(state, {:ok, event}, log_message: "#{event_type}")
      end

    {:noreply, state}
  end

  defp add_task_info(%{event_type: event_type} = event, task) do
    {task_ref, task_pid} =
      if is_nil(task) || event_type == :command_result do
        {nil, nil}
      else
        {task.ref, task.pid}
      end

    event
    |> Map.put(:task_ref, task_ref)
    |> Map.put(:task_pid, task_pid)
  end

  @spec maybe_update_os_pid(state(), map()) :: state()
  defp maybe_update_os_pid(%__MODULE__{task: nil} = state, _event), do: state

  defp maybe_update_os_pid(
         %__MODULE__{os_pid: os_pid} = state,
         event
       ) do
    event_os_pid = Map.get(event, :os_pid, 0)

    if os_pid == 0 && event_os_pid != 0 do
      %__MODULE__{state | os_pid: event_os_pid}
    else
      state
    end
  end

  @spec parse_result(map(), String.t()) :: map()
  defp parse_result(event_data, output) do
    case String.split(output, "\n") |> decode_last_json_line() do
      nil -> Map.put(event_data, :message, output)
      result -> Map.merge(event_data, result)
    end
  end

  defp decode_last_json_line(lines) do
    Enum.reduce(lines, nil, fn line, acc ->
      case Jason.decode(line, keys: :atoms) do
        {:ok, event_data} when is_map(event_data) ->
          event_data

        _ ->
          acc
      end
    end)
  end

  @spec maybe_cancel(state()) :: state()
  defp maybe_cancel(%__MODULE__{os_pid: 0} = state), do: state
  defp maybe_cancel(%__MODULE__{sigint_pending: false} = state), do: state

  defp maybe_cancel(state) do
    {_reply, state} = do_cancel(state)
    state
  end

  @spec do_cancel(state()) :: {:pending | :ok, state()}
  defp do_cancel(%__MODULE__{command_id: command_id, os_pid: os_pid} = state) do
    if os_pid == 0 do
      _ = Logger.debug("ScriptRunner #{command_id} set sigint_pending")
      {:pending, %__MODULE__{state | sigint_pending: true}}
    else
      _ = Logger.error("ScriptRunner #{command_id} sending \"kill -s INT\" to #{os_pid}")
      _ = System.cmd("kill", ["-s", "INT", to_string(os_pid)])
      {:ok, %__MODULE__{state | sigint_pending: false}}
    end
  end

  @spec maybe_send_reply(state(), term(), Keyword.t()) :: state()
  defp maybe_send_reply(
         %__MODULE__{command_id: command_id, client_from: nil} = state,
         _reply,
         opts
       ) do
    fail_silently = Keyword.get(opts, :fail_silently, false)
    log_message = Keyword.get(opts, :log_message)

    if !fail_silently && !is_nil(log_message) do
      _ = Logger.error("ScriptRunner #{command_id} no_client for #{log_message}")
    end

    state
  end

  defp maybe_send_reply(
         %__MODULE__{command_id: command_id, client_from: from} = state,
         reply,
         opts
       ) do
    log_message = Keyword.get(opts, :log_message)

    if !is_nil(log_message) do
      _ =
        Logger.error("ScriptRunner #{command_id} #{log_message} sending reply #{inspect(reply)}")
    end

    _ = GenServer.reply(from, reply)
    %__MODULE__{state | client_from: nil}
  end

  @spec shutdown_and_remove_task(state()) ::
          {term(), state()}
  defp shutdown_and_remove_task(%__MODULE__{task: nil} = state), do: {{:error, :notask}, state}

  defp shutdown_and_remove_task(
         %__MODULE__{command_id: command_id, task: %Task{pid: task_pid}} = state
       ) do
    state = demonitor_and_remove_task(state)

    reply =
      if Process.alive?(task_pid) do
        _ = Logger.debug("ScriptRunner #{command_id} shutting down pid #{inspect(task_pid)}")
        _ = Process.exit(task_pid, :shutdown)
        :ok
      else
        _ = Logger.debug("ScriptRunner #{command_id} kill #{inspect(task_pid)} already dead")
        {:error, :noproc}
      end

    {reply, state}
  end

  @spec demonitor_and_remove_task(state()) :: state()
  defp demonitor_and_remove_task(%__MODULE__{task: nil} = state), do: state

  defp demonitor_and_remove_task(
         %__MODULE__{command_id: command_id, task: %Task{ref: task_ref}} = state
       ) do
    _ = Logger.debug("ScriptRunner  #{command_id} remove_task #{inspect(task_ref)}")
    _ = Process.demonitor(task_ref, [:flush])

    %__MODULE__{state | task: nil}
  end
end
