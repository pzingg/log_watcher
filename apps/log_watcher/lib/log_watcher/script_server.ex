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
              sigint_pending: false,
              task_result: nil,
              awaiting_client: nil

    @type t() :: %__MODULE__{
            task: Elixir.Task.t(),
            task_id: String.t(),
            job_id: integer(),
            os_pid: integer(),
            sigint_pending: boolean(),
            task_result: term(),
            awaiting_client: GenServer.from() | nil
          }
  end

  @type state() :: %{required(reference()) => TaskInfo.t()}

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
  Public interface. Cancel a task by sending a SIGINT signal to the
  task's POSIX process. If the POSIX process id has not been read yet,
  the signal will be sent as soon as the process id is set.
  """
  @spec cancel(reference() | integer()) :: :ok | {:error, :not_found}
  def cancel(task_ref_or_job_id) do
    GenServer.call(__MODULE__, {:cancel, task_ref_or_job_id})
  end

  @doc """
  Public interface. Shutdown the task.
  """
  @spec kill(reference() | integer()) :: :ok | {:error, :not_found}
  def kill(task_ref_or_job_id) do
    GenServer.call(__MODULE__, {:kill, task_ref_or_job_id})
  end

  @doc """
  Public interface. Wait for the Elixir Task to complete. Note
  that the POSIX process may still be running after the Task completes.
  """
  @spec await(reference() | integer(), integer()) ::
          {:ok, term()} | {:error, :not_found | :timeout | :shutdown_requested}
  def await(task_ref_or_job_id, timeout) do
    # Prevent this by specifying (timeout + 100) in the GenServer.call:
    # ** (exit) exited in: GenServer.call(LogWatcher.ScriptServer, {:await, #Reference<0.461027745.1939865606.72509>, 10000}, 5000)
    #      ** (EXIT) time out
    GenServer.call(
      __MODULE__,
      {:await, task_ref_or_job_id, timeout},
      timeout + 100
    )
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

  @doc false
  @impl true
  @spec init(term()) :: {:ok, state()}
  def init(_arg) do
    _ = Process.flag(:trap_exit, true)
    {:ok, %{}}
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
      Map.put(state, task.ref, %TaskInfo{
        task: task,
        task_id: Map.get(start_args, :task_id),
        job_id: Map.get(start_args, :oban_job_id)
      })

    {:reply, task.ref, next_state}
  end

  def handle_call({:cancel, task_ref}, _from, state) when is_reference(task_ref) do
    case Map.get(state, task_ref) do
      %TaskInfo{} = info ->
        send_sigint_or_set_pending(task_ref, info, state)

      _nil ->
        _ = Logger.error("ScriptServer cancel, task_ref #{inspect(task_ref)} not found")
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:cancel, job_id}, _from, state) when is_integer(job_id) do
    case find_task_by_job_id(job_id, state) do
      {task_ref, %TaskInfo{} = info} ->
        send_sigint_or_set_pending(task_ref, info, state)

      _nil ->
        _ = Logger.error("ScriptServer cancel, job #{job_id} not found")
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:kill, task_ref}, _from, state)
      when is_reference(task_ref) do
    case Map.get(state, task_ref) do
      %TaskInfo{} = info ->
        next_info =
          maybe_send_reply(info, {:error, :shutdown_requested},
            fail_silently: true,
            log_message: "shutdown already requested"
          )

        {reply, next_state} = shutdown_and_remove_task(task_ref, next_info, state)
        {:reply, reply, next_state}

      _nil ->
        _ = Logger.error("ScriptServer kill task_ref #{inspect(task_ref)} not found")

        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:kill, job_id}, _from, state)
      when is_integer(job_id) do
    case find_task_by_job_id(job_id, state) do
      {task_ref, %TaskInfo{} = info} ->
        next_info =
          maybe_send_reply(info, {:error, :shutdown_requested},
            fail_silently: true,
            log_message: "shutdown already requested"
          )

        {reply, next_state} = shutdown_and_remove_task(task_ref, next_info, state)
        {:reply, reply, next_state}

      _nil ->
        _ = Logger.error("ScriptServer kill, job #{job_id} not found")
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:await, task_ref, timeout}, from, state)
      when is_reference(task_ref) do
    case Map.get(state, task_ref) do
      %TaskInfo{} = info ->
        set_awaiting_client(task_ref, info, timeout, from, state)

      _nil ->
        _ = Logger.error("ScriptServer await task_ref #{inspect(task_ref)} not found")

        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:await, job_id, timeout}, from, state)
      when is_integer(job_id) do
    case find_task_by_job_id(job_id, state) do
      {task_ref, %TaskInfo{} = info} ->
        set_awaiting_client(task_ref, info, timeout, from, state)

      _nil ->
        _ = Logger.error("ScriptServer await, job #{job_id} not found")
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update_os_pid, task_ref, os_pid}, _from, state) do
    case Map.get(state, task_ref) do
      %TaskInfo{task_id: task_id, sigint_pending: true} = info ->
        _ = Logger.error("ScriptServer update_os_pid, sending pending SIGINT to #{os_pid}")

        next_state =
          Map.put(state, task_ref, %TaskInfo{info | os_pid: os_pid, sigint_pending: false})

        {:reply, send_sigint(task_id, os_pid), next_state}

      %TaskInfo{} = info ->
        next_state = Map.put(state, task_ref, %TaskInfo{info | os_pid: os_pid})

        {:reply, :ok, next_state}

      _nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @doc false
  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:await_timed_out, task_ref}, state) do
    # Yield timer has expired, so send `{:error, :timeout}` reply
    case Map.get(state, task_ref) do
      %TaskInfo{} = info ->
        next_info = maybe_send_reply(info, {:error, :timeout}, log_message: "await timed out")
        next_state = Map.put(state, task_ref, next_info)
        {:noreply, next_state}

      _nil ->
        _ = Logger.error("ScriptServer await timed out #{inspect(task_ref)} already removed")
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, task_ref, _, _, reason}, state) do
    # What does :noconnection reason mean? See Task.yield implementation.
    case Map.get(state, task_ref) do
      %TaskInfo{task_id: task_id} ->
        _ = Logger.error("ScriptServer task #{task_id} DOWN with reason #{inspect(reason)}")

        {:noreply, demonitor_and_remove_task(task_ref, state)}

      _nil ->
        _ = Logger.error("ScriptServer DOWN task_ref #{inspect(task_ref)} already removed")
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    _ = Logger.error("ScriptServer EXIT #{inspect(pid)} with reason #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    # Task completed with `result`
    case Map.get(state, task_ref) do
      %TaskInfo{} = info ->
        # Send result back to the `from` client of `handle_call({:await, ...)`.
        result_to_send = format_result(result)

        _next_info =
          maybe_send_reply(info, result_to_send,
            log_message: "ref sending result #{inspect(result_to_send)}"
          )

        # The task succeeded so we can cancel the monitoring and discard the DOWN message
        {:noreply, demonitor_and_remove_task(task_ref, state)}

      _nil ->
        _ = Logger.error("ScriptServer ref #{inspect(task_ref)} already removed")
        {:noreply, state}
    end
  end

  def handle_info(unexpected, state) do
    _ = Logger.error("ScriptServer unexpected message #{inspect(unexpected)}")
    {:noreply, state}
  end

  # Private functions

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
    _ =
      Logger.info("ScriptServer task #{task_id} do_run_script start_args #{inspect(start_args)}")

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
          "ScriptServer task #{task_id} shelling out to #{executable} with args #{
            inspect(script_args)
          }"
        )

      {output, exit_status} =
        System.cmd(executable, [script_path | script_args], cd: Path.dirname(script_path))

      _ = Logger.info("ScriptServer task #{task_id} script exited with #{exit_status}")
      _ = Logger.info("ScriptServer task #{task_id} output from script: #{inspect(output)}")

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

  @spec find_task_by_job_id(integer(), state()) :: {reference(), TaskInfo.t()} | nil
  defp find_task_by_job_id(job_id, state) do
    Enum.find(state, fn {_ref, %TaskInfo{job_id: id}} -> id == job_id end)
  end

  @spec send_sigint_or_set_pending(reference(), TaskInfo.t(), state()) ::
          {:reply, :pending | :ok, state()}
  defp send_sigint_or_set_pending(
         task_ref,
         %TaskInfo{task_id: task_id, os_pid: 0} = info,
         state
       ) do
    _ = Logger.info("ScriptServer task #{task_id} set sigint_pending")

    next_state = Map.put(state, task_ref, %TaskInfo{info | sigint_pending: true})

    {:reply, :pending, next_state}
  end

  defp send_sigint_or_set_pending(
         task_ref,
         %TaskInfo{task_id: task_id, os_pid: os_pid} = info,
         state
       ) do
    _ = Logger.info("ScriptServer task #{task_id} send sigint")

    next_state = Map.put(state, task_ref, %TaskInfo{info | sigint_pending: false})

    {:reply, send_sigint(task_id, os_pid), next_state}
  end

  @spec send_sigint(String.t(), integer()) :: :ok | {:error, :no_pid}
  defp send_sigint(_task_id, 0), do: {:error, :no_pid}

  defp send_sigint(task_id, os_pid) do
    _ = Logger.error("ScriptServer task #{task_id} sending \"kill -s INT\" to #{os_pid}")
    _ = System.cmd("kill", ["-s", "INT", to_string(os_pid)])
    :ok
  end

  @spec set_awaiting_client(reference(), TaskInfo.t(), integer(), GenServer.from(), state()) ::
          {:reply, :ok | {:error, :shutting_down}, state()}
  defp set_awaiting_client(
         task_ref,
         %TaskInfo{task_id: task_id, awaiting_client: nil} = info,
         timeout,
         from,
         state
       ) do
    # Set timer to expire yield, and save `from` for reply
    _ = Process.send_after(self(), {:await_timed_out, task_ref}, timeout)

    next_state = Map.put(state, task_ref, %TaskInfo{info | awaiting_client: from})
    _ = Logger.info("ScriptServer task #{task_id} yield client set")

    # Reply will come later from `handle_info({task_ref, result}, ...)`.
    {:noreply, next_state}
  end

  defp set_awaiting_client(
         _task_ref,
         %TaskInfo{task_id: task_id},
         _timeout,
         _from,
         state
       ) do
    _ = Logger.error("ScriptServer task #{task_id} yield client already set")
    {:reply, {:error, :shutting_down}, state}
  end

  @spec format_result(term()) :: {:ok, term()} | {:error, term()}
  defp format_result({:ok, _} = result), do: result
  defp format_result({:error, _} = result), do: result

  # Handles `:ok` to `{:ok, :ok}` for example
  defp format_result(other), do: {:ok, other}

  @spec maybe_send_reply(TaskInfo.t(), term(), Keyword.t()) :: TaskInfo.t()
  defp maybe_send_reply(
         %TaskInfo{task_id: task_id, awaiting_client: nil} = info,
         reply,
         opts
       ) do
    fail_silently = Keyword.get(opts, :fail_silently, false)
    log_message = Keyword.get(opts, :log_message)

    if !fail_silently && !is_nil(log_message) do
      _ =
        Logger.error(
          "ScriptServer task #{task_id} #{log_message} no client for reply #{inspect(reply)}"
        )
    end

    info
  end

  defp maybe_send_reply(
         %TaskInfo{task_id: task_id, awaiting_client: from} = info,
         reply,
         opts
       ) do
    log_message = Keyword.get(opts, :log_message)

    if !is_nil(log_message) do
      _ =
        Logger.error(
          "ScriptServer task #{task_id} #{log_message} sending reply #{inspect(reply)}"
        )
    end

    _ = GenServer.reply(from, reply)
    %TaskInfo{info | awaiting_client: nil}
  end

  @spec shutdown_and_remove_task(reference(), TaskInfo.t(), state()) ::
          {term(), state()}
  defp shutdown_and_remove_task(
         task_ref,
         %TaskInfo{task: task, task_id: task_id} = info,
         state
       ) do
    next_state = demonitor_and_remove_task(task_ref, state)

    reply =
      cond do
        is_nil(task.pid) ->
          _ = Logger.error("ScriptServer task #{task_id} kill no pid")
          {:error, :no_pid}

        Process.alive?(task.pid) ->
          _ = Logger.error("ScriptServer task #{task_id} shutting down pid #{inspect(task.pid)}")
          _ = Process.exit(task.pid, :shutdown)
          :ok

        true ->
          _ = Logger.error("ScriptServer task #{task_id} kill #{inspect(task.pid)} already dead")

          {:error, :noproc}
      end

    {reply, next_state}
  end

  @spec demonitor_and_remove_task(reference(), state()) :: state()
  defp demonitor_and_remove_task(task_ref, state) do
    _ = Logger.error("ScriptServer remove_task #{inspect(task_ref)}")
    _ = Process.demonitor(task_ref, [:flush])

    Map.delete(state, task_ref)
  end
end
