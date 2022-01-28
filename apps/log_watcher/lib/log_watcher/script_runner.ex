defmodule LogWatcher.ScriptRunner do
  @moduledoc """
  A GenServer that runs scripts.
  """
  use GenServer

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
            await_start: false,
            sigint_pending: false,
            task: nil,
            awaiting_start: nil,
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
          await_start: boolean(),
          sigint_pending: boolean(),
          task: Task.t() | nil,
          awaiting_start: GenServer.from() | nil,
          other_waiters: [{:atom, GenServer.from()}]
        }

  @type gproc_key :: {:n, :l, {:command_id, String.t()}}

  @event_data_keys [
    :session_id,
    :log_dir,
    :command_id,
    :name,
    :gen
  ]

  # Public interface

  def start_link(%{command_id: command_id} = arg) do
    GenServer.start_link(__MODULE__, arg, name: via_tuple(command_id))
  end

  def start_link(_arg), do: {:error, :badarg}

  def run_script(command_id, script_path, start_args) do
    GenServer.call(via_tuple(command_id), {:run_script, script_path, start_args})
  end

  def await_exit(command_id, timeout) when is_integer(timeout) do
    GenServer.call(via_tuple(command_id), {:await, :command_exit, timeout}, timeout + 1000)
  end

  def cancel(command_id) do
    GenServer.call(via_tuple(command_id), :cancel)
  end

  def kill(command_id) do
    GenServer.call(via_tuple(command_id), :kill)
  end

  @doc """
  Convenience method to send an Elixir message to the ScriptRunner process if
  it still alive, and posting it to the Broadway pipeline.
  """
  @spec send_event(String.t(), atom(), map()) :: :ok
  def send_event(command_id, event_type, data) do
    event = Map.put(data, :event_type, event_type)

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
  Return the pid for a server.
  """
  @spec whereis(String.t()) :: pid() | :undefined
  def whereis(command_id) do
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

    state = %__MODULE__{
      command_args: command_args,
      session_id: session.id,
      log_dir: session.log_dir,
      gen: session.gen,
      command_id: command_id,
      command_name: command_name,
      job_id: Map.get(command_args, :oban_job_id, 0),
      cancel: Map.get(command_args, :cancel, ""),
      script_path: Map.get(command_args, :script_path)
    }

    {:ok, state}
  end

  def init(_arg), do: {:error, :badarg}

  @doc false
  @impl true
  def handle_call(
        {:run_script, await_start},
        from,
        %__MODULE__{
          session_id: session_id,
          log_dir: log_dir,
          gen: gen,
          command_id: command_id,
          command_name: command_name,
          awaiting_start: nil
        } = state
      ) do
    start_args = encode_start_args(state)
    _ = write_start_args(state, start_args)

    log_path =
      Path.join(log_dir, Command.log_file_name(session_id, gen, command_id, command_name))

    FileWatcherManager.watch(session_id, command_id, log_path)

    send(self(), {:start_script_task, from})

    # We will return the reply after the script has started or terminated.
    {:noreply, %__MODULE__{state | await_start: await_start}}
  end

  def handle_call({:run_script, _await_start}, _from, state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call({:await, wait_type, timeout}, from, %__MODULE__{other_waiters: waiters} = state) do
    Process.send_after(self(), {:timeout, wait_type, from}, timeout)
    {:noreply, %__MODULE__{state | other_waiters: [{wait_type, from} | waiters]}}
  end

  def handle_call(:cancel, _from, state) do
    {reply, state} = do_cancel(state)
    {:reply, reply, state}
  end

  def handle_call(:kill, _from, state) do
    state =
      maybe_send_reply(
        state,
        {:error, :shutdown_requested},
        fail_silently: true,
        log_message: "shutdown already requested"
      )

    {reply, state} = shutdown_and_remove_task(state)
    {:reply, reply, state}
  end

  @doc false
  @impl true
  def handle_info({:start_script_task, from}, %__MODULE__{command_id: command_id} = state) do
    task =
      Task.Supervisor.async_nolink(LogWatcher.TaskSupervisor, fn ->
        do_run_script(state)
      end)

    send(LogWatcher.CommandManager, {:task_started, command_id, task})

    # After we start the task, we store its reference and pid
    {:noreply, %__MODULE__{state | task: task, awaiting_start: from}}
  end

  def handle_info({:timeout, wait_type, from}, %__MODULE__{other_waiters: waiters} = state) do
    # state = maybe_send_reply(state, {:error, :timeout}, log_message: "timeout")
    GenServer.reply(from, {:error, :timeout})
    {:noreply, %__MODULE__{state | other_waiters: List.delete(waiters, {wait_type, from})}}
  end

  def handle_info({:command_event, event}, state) do
    handle_command_event(event, state)
  end

  def handle_info(
        {task_ref, result},
        %__MODULE__{command_id: command_id, task: %Task{ref: task_ref}} = state
      ) do
    _ = Logger.info("ScriptRunner #{command_id} received command result")

    state =
      maybe_send_reply(state, {:error, {:command_result, result}}, log_message: "command result")

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, task_ref, :process, _pid, reason},
        %__MODULE__{command_id: command_id, task: %Task{ref: task_ref}, other_waiters: waiters} =
          state
      ) do
    _ = Logger.info("ScriptRunner #{command_id} received command exit #{reason}")

    # Will only send this if :command_result was never sent.
    state =
      maybe_send_reply(%__MODULE__{state | task: nil}, {:error, {:command_exit, reason}},
        log_message: "command exit #{reason}"
      )

    # If anyone else was waiting...
    for {_wait_type, from} <- waiters do
      GenServer.reply(from, {:ok, :command_exit})
    end

    {:noreply, %__MODULE__{state | task: nil, other_waiters: []}}
  end

  def handle_info({:DOWN, ref, pid, reason}, %__MODULE__{command_id: command_id} = state) do
    Logger.error("ScriptRunner #{command_id} :DOWN #{inspect(ref)} #{inspect(pid)} #{reason}")
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %__MODULE__{command_id: command_id} = state) do
    _ = Logger.info("ScriptRunner #{command_id} :EXIT #{inspect(pid)} #{reason}")
    {_, state} = do_cancel(state)

    state =
      maybe_send_reply(state, {:error, reason}, log_message: ":EXIT #{inspect(pid)} #{reason}")

    {:noreply, state}
  end

  def handle_info(unexpected, %__MODULE__{command_id: command_id} = state) do
    _ = Logger.error("ScriptRunner #{command_id} unexpected #{inspect(unexpected)}")
    state = maybe_send_reply(state, {:error, :unimplemented}, log_message: "unexpected")
    {:noreply, state}
  end

  @doc false
  @impl true
  def terminate(reason, %__MODULE__{command_id: command_id}) do
    Logger.error("ScriptRunner #{command_id} terminate #{reason}")
    :ok
  end

  # Private functions

  @spec registry_key(String.t()) :: gproc_key()
  defp registry_key(command_id) do
    {:n, :l, {:command_id, command_id}}
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

  defp write_start_args(
         %__MODULE__{
           command_id: command_id,
           command_name: command_name,
           session_id: session_id,
           log_dir: log_dir,
           gen: gen
         },
         start_args
       ) do
    arg_path =
      Path.join(log_dir, Command.arg_file_name(session_id, gen, command_id, command_name))

    _ = Logger.info("ScriptRunner #{command_id}: write arg file to #{arg_path}")

    Commands.write_arg_file(arg_path, start_args)
  end

  @spec do_run_script(state()) ::
          {:ok, map()} | {:error, term()}
  defp do_run_script(
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
      Logger.info(
        "ScriptRunner #{command_id} run_script #{script_path} with #{inspect(script_args)}"
      )

    executable =
      if String.ends_with?(script_path, ".R") do
        System.find_executable("Rscript")
      else
        System.find_executable("python3")
      end

    data =
      script_args
      |> Map.merge(Map.from_struct(state))
      |> Enum.filter(fn {key, _value} -> Enum.member?(@event_data_keys, key) end)
      |> Map.new()

    if is_nil(executable) do
      data =
        data
        |> Map.put(:message, "no executable for #{Path.basename(script_path)}")
        |> Map.put(:status, "completed")

      _ = send_event(command_id, :no_executable, data)

      {:error, data}
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
        Logger.info(
          "ScriptRunner #{command_id} shelling out to #{executable} with args #{inspect(shell_args)}"
        )

      {output, exit_status} =
        System.cmd(executable, [script_path | shell_args], cd: Path.dirname(script_path))

      _ = Logger.info("ScriptRunner #{command_id} script exited with #{exit_status}")
      _ = Logger.info("ScriptRunner #{command_id} output from script: #{inspect(output)}")

      data =
        data
        |> Map.put(:status, "completed")
        |> Map.put(:exit_status, exit_status)
        |> parse_result(output)

      _ = send_event(command_id, :command_result, data)

      {:ok, data}
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

  defp handle_command_event(
         %{event_type: event_type} = event,
         %__MODULE__{command_id: command_id, task: task, await_start: await_start} = state
       ) do
    _ = Logger.info("ScriptRunner #{command_id} received #{event_type}")

    # Include task information in event
    event = add_task_info(event, task)

    state =
      if event_type == :command_updated do
        state
        |> maybe_update_os_pid(event)
        |> maybe_cancel(event)
      else
        state
      end

    state =
      if event_type == :command_updated && await_start do
        state
      else
        # :command_started, :command_result
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

  @spec maybe_cancel(state(), map()) :: state()
  defp maybe_cancel(%__MODULE__{task: nil} = state, _event), do: state

  defp maybe_cancel(
         %__MODULE__{command_id: command_id, cancel: cancel} = state,
         %{status: status}
       ) do
    if status == cancel do
      _ =
        Logger.error(
          "ScriptRunner #{command_id}: cancelling script, last status read was #{status}"
        )

      {reply, state} = do_cancel(%__MODULE__{state | cancel: "sent"})
      maybe_send_reply(state, reply, log_message: "cancel")
    else
      state
    end
  end

  @spec parse_result(map(), String.t()) :: map()
  defp parse_result(data, output) do
    case String.split(output, "\n") |> get_last_json_line() do
      nil -> Map.put(data, :message, output)
      result -> Map.merge(data, result)
    end
  end

  defp get_last_json_line(lines) do
    Enum.reduce(lines, nil, fn line, acc ->
      case Jason.decode(line, keys: :atoms) do
        {:ok, data} when is_map(data) ->
          data

        _ ->
          acc
      end
    end)
  end

  @spec do_cancel(state()) :: {:pending | :ok, state()}
  defp do_cancel(%__MODULE__{command_id: command_id, os_pid: os_pid} = state) do
    if is_nil(os_pid) do
      _ = Logger.info("ScriptRunner #{command_id} set sigint_pending")
      {:pending, %__MODULE__{state | sigint_pending: true}}
    else
      _ = Logger.error("ScriptRunner #{command_id} sending \"kill -s INT\" to #{os_pid}")
      _ = System.cmd("kill", ["-s", "INT", to_string(os_pid)])
      {:ok, %__MODULE__{state | sigint_pending: false, os_pid: 0}}
    end
  end

  @spec maybe_send_reply(state(), term(), Keyword.t()) :: state()
  defp maybe_send_reply(
         %__MODULE__{command_id: command_id, awaiting_start: nil} = state,
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
         %__MODULE__{command_id: command_id, awaiting_start: from} = state,
         reply,
         opts
       ) do
    log_message = Keyword.get(opts, :log_message)

    if !is_nil(log_message) do
      _ =
        Logger.error("ScriptRunner #{command_id} #{log_message} sending reply #{inspect(reply)}")
    end

    _ = GenServer.reply(from, reply)
    %__MODULE__{state | awaiting_start: nil}
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
        _ = Logger.error("ScriptRunner #{command_id} shutting down pid #{inspect(task_pid)}")
        _ = Process.exit(task_pid, :shutdown)
        :ok
      else
        _ = Logger.error("ScriptRunner #{command_id} kill #{inspect(task_pid)} already dead")
        {:error, :noproc}
      end

    {reply, state}
  end

  @spec demonitor_and_remove_task(state()) :: state()
  defp demonitor_and_remove_task(%__MODULE__{task: nil} = state), do: state

  defp demonitor_and_remove_task(
         %__MODULE__{command_id: command_id, task: %Task{ref: task_ref}} = state
       ) do
    _ = Logger.error("ScriptRunner  #{command_id} remove_task #{inspect(task_ref)}")
    _ = Process.demonitor(task_ref, [:flush])

    %__MODULE__{state | task: nil}
  end
end
