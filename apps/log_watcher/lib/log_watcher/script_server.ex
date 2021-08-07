defmodule LogWatcher.ScriptServer do
  @moduledoc """
  A GenServer that launches long-running POSIX shell scripts (as implemented
  in Python or R) under an Elixir Task, and can cancel them by sending
  SIGINT signals. The shell scripts are expected to produce JSON line
  output on stdout which is captured and parsed when the script (and Elixir
  Task) terminate.

  We could use Elixir Ports for this work, but this implementation is
  potentially simpler. Progress and other information from the
  script is captured by a different process, the `LogWatcher.FileWatcher`.
  """

  use GenServer

  require Logger

  alias LogWatcher.Tasks.Session

  defmodule TaskInfo do
    @enforce_keys [:task, :task_id, :job_id]

    defstruct task: nil,
              task_id: nil,
              job_id: 0,
              os_pid: 0,
              task_result: nil,
              sigint_pending: false,
              yield_client: nil

    @type t() :: %__MODULE__{
            task: Elixir.Task.t(),
            task_id: String.t(),
            job_id: integer(),
            os_pid: integer(),
            task_result: term(),
            sigint_pending: boolean(),
            yield_client: pid()
          }
  end

  defstruct tasks: %{}

  @type state() :: %__MODULE__{
          tasks: %{required(reference()) => TaskInfo.t()}
        }

  @info_keys [
    :session_id,
    :session_log_path,
    :task_id,
    :task_type,
    :gen
  ]

  @doc """
  Public interface. Start a linked GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Public interface. Launch and monitor a shell script.
  """
  @spec run_script(String.t(), map()) :: reference()
  def run_script(script_path, start_args) do
    GenServer.call(__MODULE__, {:run_script, script_path, start_args})
  end

  @doc """
  Public interface. Update the GenServer, to associate the POSIX process id
  of the running script with the Elixir task that launched the script
  (similar to an Elixir Port).
  """
  @spec update_os_pid(reference(), integer()) :: :ok | {:error, :not_found}
  def update_os_pid(task_ref, os_pid) do
    GenServer.call(__MODULE__, {:update_os_pid, task_ref, os_pid})
  end

  @doc """
  Public interface. Send a SIGINT signal to the POSIX process via a "kill"
  shell command. If the POSIX process id has not been read yet, the signal
  will be sent as soon as the process id is set. The argument can be either
  the Elixir Task reference, or the Oban job id associated with the task.
  """
  @spec cancel_script(reference() | integer()) :: :ok | {:error, :not_found}
  def cancel_script(task_ref_or_job_id) do
    GenServer.call(__MODULE__, {:cancel_script, task_ref_or_job_id})
  end

  @doc """
  Public interface. Wait for the Elixir Task to complete, or send the Task's
  process an exit signal.
  """
  @spec yield_or_shutdown_task(reference(), integer()) ::
          :ok | {:ok, term()} | {:error, :timeout}
  def yield_or_shutdown_task(task_ref, timeout) do
    # Prevent this by specifying (timeout + 100) in the GenServer.call:
    # ** (exit) exited in: GenServer.call(LogWatcher.ScriptServer, {:yield_or_shutdown, #Reference<0.461027745.1939865606.72509>, 10000}, 5000)
    #      ** (EXIT) time out
    GenServer.call(__MODULE__, {:yield_or_shutdown, task_ref, timeout}, timeout + 100)
  end

  @doc false
  @impl true
  @spec init(term()) :: {:ok, state()}
  def init(_arg) do
    _ = Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{}}
  end

  @doc false
  @impl true
  @spec handle_call(term(), GenServer.from(), state()) ::
          {:reply, term(), state()} | {:noreply, state()}
  def handle_call({:run_script, script_path, start_args}, _from, state) do
    _ = Logger.info("ScriptServer run_script #{script_path}")

    task =
      Elixir.Task.Supervisor.async_nolink(LogWatcher.TaskSupervisor, fn ->
        do_run_script(script_path, start_args)
      end)

    # After we start the task, we store its reference and the url it is fetching
    next_state =
      put_in(state.tasks[task.ref], %TaskInfo{
        task: task,
        task_id: Map.get(start_args, :task_id),
        job_id: Map.get(start_args, :oban_job_id)
      })

    {:reply, task.ref, next_state}
  end

  def handle_call({:update_os_pid, task_ref, os_pid}, _from, state) do
    case Map.get(state.tasks, task_ref) do
      %TaskInfo{task_id: task_id, sigint_pending: true} = info ->
        _ = Logger.error("ScriptServer update_os_pid, sending pending SIGINT to #{os_pid}")

        next_state =
          put_in(
            state.tasks[task_ref],
            %TaskInfo{info | os_pid: os_pid, sigint_pending: false}
          )

        {:reply, send_sigint(task_id, os_pid), next_state}

      %TaskInfo{} = info ->
        next_state =
          put_in(
            state.tasks[task_ref],
            %TaskInfo{info | os_pid: os_pid}
          )

        {:reply, :ok, next_state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:cancel_script, task_ref}, _from, state) when is_reference(task_ref) do
    case Map.get(state.tasks, task_ref) do
      nil ->
        _ = Logger.error("ScriptServer cancel_script, task_ref #{inspect(task_ref)} not found")
        {:reply, {:error, :not_found}, state}

      info ->
        handle_cancel(task_ref, info, state)
    end
  end

  def handle_call({:cancel_script, job_id}, _from, state) when is_integer(job_id) do
    case find_task_by_job_id(job_id, state) do
      nil ->
        _ = Logger.error("ScriptServer cancel_script, job #{job_id} not found")
        {:reply, {:error, :not_found}, state}

      {task_ref, info} ->
        handle_cancel(task_ref, info, state)
    end
  end

  def handle_call({:yield_or_shutdown, task_ref, timeout}, from, state) do
    case Map.get(state.tasks, task_ref) do
      %TaskInfo{yield_client: yield_client} when is_pid(yield_client) ->
        _ = Logger.error("ScriptServer :yield_or_shutdown already shutting down")
        {:reply, {:error, :shutting_down}, state}

      %TaskInfo{} = info ->
        _ = Logger.info("ScriptServer :yield_or_shutdown")
        _ = Process.send_after(self(), {:yield_timeout, task_ref}, timeout)

        next_state =
          put_in(
            state.tasks[task_ref],
            %TaskInfo{info | yield_client: from}
          )

        _ = Logger.info("next state is now #{inspect(next_state)}")
        {:noreply, next_state}

      _ ->
        _ = Logger.error("ScriptServer :yield_or_shutdown task_ref not found")
        {:reply, {:error, :not_found}, state}
    end
  end

  @doc false
  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:yield_timeout, task_ref}, state) do
    case Map.get(state.tasks, task_ref) do
      %TaskInfo{task_id: task_id, yield_client: nil} ->
        _ = Logger.error("ScriptServer :yield_timeout for task #{task_id}, no client")
        {:noreply, state}

      %TaskInfo{task: task, task_id: task_id, yield_client: yield_client} = info ->
        _ = Logger.error("ScriptServer :yield_timeout for task #{task_id}")
        GenServer.reply(yield_client, {:error, :timeout})

        _ = Process.exit(task.pid, :shutdown)

        next_state =
          put_in(
            state.tasks[task_ref],
            %TaskInfo{info | yield_client: nil}
          )

        {:noreply, next_state}

      _ ->
        _ = Logger.error("ScriptServer :yield_timeout #{inspect(task_ref)} already removed")
        {:noreply, state}
    end
  end

  def handle_info({task_ref, result}, state) do
    case Map.get(state.tasks, task_ref) do
      nil ->
        _ = Logger.error("ScriptServer ref #{inspect(task_ref)} already removed")
        {:noreply, state}

      %TaskInfo{task_id: task_id, yield_client: yield_client} ->
        _ = Logger.error("ScriptServer ref for task #{task_id} got #{inspect(result)}")

        # The task succeeded so we can cancel the monitoring and discard the DOWN message
        _ = Process.demonitor(task_ref, [:flush])

        if !is_nil(yield_client) do
          _ = Logger.error("ScriptServer ref replying with result")
          _ = GenServer.reply(yield_client, result)
        end

        next_state = %__MODULE__{state | tasks: Map.delete(state.tasks, task_ref)}
        {:noreply, next_state}
    end
  end

  def handle_info({:DOWN, task_ref, _, _, reason}, state) do
    # What does :noconnection reason mean? See Task.yield implementation.
    case Map.get(state.tasks, task_ref) do
      nil ->
        _ = Logger.error("ScriptServer :DOWN task_ref #{inspect(task_ref)} already removed")
        {:noreply, state}

      %TaskInfo{task_id: task_id} ->
        _ = Logger.error("ScriptServer task #{task_id} failed with reason #{inspect(reason)}")
        next_state = %__MODULE__{state | tasks: Map.delete(state.tasks, task_ref)}
        {:noreply, next_state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    _ = Logger.error("ScriptServer :EXIT #{inspect(pid)} with reason #{inspect(reason)}")
    {:noreply, state}
  end

  @spec find_task_by_job_id(integer(), state()) :: {reference(), TaskInfo.t()} | nil
  defp find_task_by_job_id(job_id, state) do
    Enum.find(state.tasks, fn
      {_ref, %TaskInfo{job_id: ^job_id}} -> true
      _ -> false
    end)
  end

  @spec handle_cancel(reference(), TaskInfo.t(), state()) :: {:reply, :pending | :ok, state()}
  defp handle_cancel(task_ref, %TaskInfo{task_id: task_id, os_pid: os_pid} = info, state) do
    case os_pid do
      0 ->
        _ = Logger.error("ScriptServer cancel_script, no os_pid available")

        next_state =
          put_in(
            state.tasks[task_ref],
            %TaskInfo{info | sigint_pending: true}
          )

        {:reply, :pending, next_state}

      _ ->
        _ = Logger.error("ScriptServer cancel_script, sending SIGINT to #{os_pid}")

        next_state =
          put_in(
            state.tasks[task_ref],
            %TaskInfo{info | sigint_pending: false}
          )

        {:reply, send_sigint(task_id, os_pid), next_state}
    end
  end

  @spec send_sigint(String.t(), integer()) :: :ok | {:error, :no_pid}
  defp send_sigint(_task_id, 0), do: {:error, :no_pid}

  defp send_sigint(task_id, os_pid) do
    _ = Logger.error("ScriptServer task #{task_id}, sending SIGINT to #{os_pid}")
    _ = System.cmd("kill", ["-s", "INT", to_string(os_pid)])
    :ok
  end

  @spec do_run_script(
          String.t(),
          map()
        ) ::
          {:ok, map()} | {:error, term()}
  defp do_run_script(
         script_path,
         %{
           session_log_path: session_log_path,
           session_id: session_id,
           task_id: task_id,
           task_type: task_type,
           gen: gen
         } = start_args
       ) do
    _ = Logger.info("ScriptServer task #{task_id}: start_args #{inspect(start_args)}")

    info =
      start_args
      |> Enum.filter(fn {key, _value} -> Enum.member?(@info_keys, key) end)
      |> Map.new()

    executable =
      if String.ends_with?(script_path, ".R") do
        System.find_executable("Rscript")
      else
        System.find_executable("python3")
      end

    if is_nil(executable) do
      {:error,
       info
       |> Map.put(:message, "no executable for #{Path.basename(script_path)}")
       |> Map.put(:status, "completed")}
    else
      basic_args = [
        "--log-path",
        session_log_path,
        "--session-id",
        session_id,
        "--task-id",
        task_id,
        "--task-type",
        task_type,
        "--gen",
        to_string(gen)
      ]

      script_args =
        Enum.reduce([:error], basic_args, fn key, acc ->
          value = Map.get(start_args, key)

          if is_binary(value) && value != "" do
            acc ++ ["--#{key}", value]
          else
            acc
          end
        end)

      _ =
        Logger.info(
          "ScriptServer task #{task_id}: shelling out to #{executable} with args #{
            inspect(script_args)
          }"
        )

      {output, exit_status} =
        System.cmd(executable, [script_path | script_args], cd: Path.dirname(script_path))

      _ = Logger.info("ScriptServer task #{task_id}: script exited with #{exit_status}")
      _ = Logger.info("ScriptServer task #{task_id}: output from script: #{inspect(output)}")

      parse_script_output(info, output, exit_status)
    end
  end

  @spec parse_script_output(map(), String.t(), integer()) :: {:ok, map()}
  defp parse_script_output(info, output, exit_status) do
    payload =
      case String.split(output, "\n") |> get_last_json_line() do
        nil ->
          info
          |> Map.put(:message, output)
          |> Map.put(:status, "completed")
          |> Map.put(:exit_status, exit_status)

        data ->
          info
          |> Map.merge(data)
          |> Map.put(:status, "completed")
          |> Map.put(:exit_status, exit_status)
      end

    Session.events_topic(info.session_id)
    |> Session.broadcast({:script_terminated, payload})

    {:ok, payload}
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
end
