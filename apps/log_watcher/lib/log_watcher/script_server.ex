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
              sigint_pending: false

    @type t() :: %__MODULE__{
            task: Elixir.Task.t(),
            task_id: String.t(),
            job_id: integer(),
            os_pid: integer(),
            sigint_pending: boolean()
          }
  end

  defstruct tasks: %{}

  @type t() :: %__MODULE__{
          tasks: %{required(reference()) => TaskInfo.t()}
        }

  @info_keys [
    :session_id,
    :session_log_path,
    :task_id,
    :task_type,
    :gen
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  def run_script(script_path, start_args) do
    GenServer.call(__MODULE__, {:run_script, script_path, start_args})
  end

  def update_os_pid(task_ref, os_pid) do
    GenServer.call(__MODULE__, {:update_os_pid, task_ref, os_pid})
  end

  @spec cancel_script(String.t()) :: :ok | {:error, :not_found}
  def cancel_script(job_id) do
    GenServer.call(__MODULE__, {:cancel_script, job_id})
  end

  @spec yield_or_shutdown_task(reference(), integer()) ::
          :ok | {:ok, term()} | {:error, :timeout}
  def yield_or_shutdown_task(task_ref, timeout) do
    GenServer.call(__MODULE__, {:yield_or_shutdown, task_ref, timeout})
  end

  @spec send_sigint(String.t(), integer()) :: :ok | {:error, :no_pid}
  def send_sigint(_task_id, 0), do: {:error, :no_pid}

  def send_sigint(task_id, os_pid) do
    Logger.error("ScriptServer task #{task_id}, sending SIGINT to #{os_pid}")
    _ = System.cmd("kill", ["-s", "INT", to_string(os_pid)])
    :ok
  end

  @impl true
  def init(_arg) do
    # We will keep all running tasks in a map
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:run_script, script_path, start_args}, _from, state) do
    Logger.info("ScriptServer run_script #{script_path}")

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
        Logger.error("ScriptServer update_os_pid, sending pending SIGINT to #{os_pid}")

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

  def handle_call({:cancel_script, job_id}, _from, state) do
    case find_task_by_job_id(job_id, state) do
      {task_ref, %TaskInfo{os_pid: 0} = info} ->
        Logger.error("ScriptServer cancel_script, no os_pid available")

        next_state =
          put_in(
            state.tasks[task_ref],
            %TaskInfo{info | sigint_pending: true}
          )

        {:reply, :pending, next_state}

      {task_ref, %TaskInfo{task_id: task_id, os_pid: os_pid} = info} ->
        Logger.error("ScriptServer cancel_script, sending SIGINT to #{os_pid}")

        next_state =
          put_in(
            state.tasks[task_ref],
            %TaskInfo{info | sigint_pending: false}
          )

        {:reply, send_sigint(task_id, os_pid), next_state}

      nil ->
        Logger.error("ScriptServer cancel_script, job #{job_id} not found")
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:yield_or_shutdown, task_ref, timeout}, _from, state) do
    Logger.info("ScriptServer yielding to script task #{inspect(task_ref)}...")

    case Map.get(state.tasks, task_ref) do
      %TaskInfo{task: task} ->
        # The task succeeded so we can cancel the monitoring and discard the DOWN message
        Process.demonitor(task_ref, [:flush])
        next_state = %__MODULE__{state | tasks: Map.delete(state.tasks, task_ref)}

        case Elixir.Task.yield(task, timeout) || Elixir.Task.shutdown(task) do
          {:ok, result} ->
            case result do
              :ok ->
                Logger.info("ScriptServer after yield, script task returned :ok")
                {:reply, :ok, next_state}

              _ ->
                Logger.info("ScriptServer after yield, script task returned #{inspect(result)}")
                {:reply, {:ok, result}, next_state}
            end

          nil ->
            Logger.warn("ScriptServer after yield, failed to get a result from script task in #{timeout}ms")
            {:reply, {:error, :timeout}, next_state}
        end

      _ ->
        Logger.error("ScriptServer task_ref not found")
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({task_ref, result}, state) do
    # The task succeeded so we can cancel the monitoring and discard the DOWN message
    Process.demonitor(task_ref, [:flush])

    {%TaskInfo{task_id: task_id}, next_state} = pop_in(state.tasks[task_ref])
    Logger.error("ScriptServer task #{task_id} got #{inspect(result)}")
    {:noreply, next_state}
  end

  def handle_info({:DOWN, task_ref, _, _, reason}, state) do
    {%TaskInfo{task_id: task_id}, next_state} = pop_in(state.tasks[task_ref])

    Logger.error("ScriptServer task #{task_id} failed with reason #{inspect(reason)}")
    {:noreply, next_state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.error("ScriptServer :EXIT #{inspect(pid)} with reason #{inspect(reason)}")
    {:noreply, state}
  end

  @spec find_task_by_job_id(String.t(), t()) :: {reference(), TaskInfo.t()} | nil
  defp find_task_by_job_id(job_id, state) do
    Enum.find(state.tasks, fn
      {_ref, %TaskInfo{job_id: ^job_id}} -> true
      _ -> false
    end)
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
    Logger.info("ScriptServer task #{task_id}: start_args #{inspect(start_args)}")

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
        case start_args[:error] do
          "" ->
            basic_args

          error when is_binary(error) ->
            basic_args ++ ["--error", error]

          _ ->
            basic_args
        end

      Logger.info(
        "ScriptServer task #{task_id}: shelling out to #{executable} with args #{
          inspect(script_args)
        }"
      )

      {output, exit_status} =
        System.cmd(executable, [script_path | script_args], cd: Path.dirname(script_path))

      Logger.info("ScriptServer task #{task_id}: script exited with #{exit_status}")
      Logger.info("ScriptServer task #{task_id}: output from script: #{inspect(output)}")

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
