defmodule LogWatcher.TaskStarter do
  use Oban.Worker, queue: :tasks

  require Logger

  alias LogWatcher.{FileWatcher, Tasks}
  alias LogWatcher.Tasks.{Session, Task}

  # To start a job
  # %{id: 100, session_id: "S2", session_log_path: "path_to_output",
  #    task_id: task_id, task_type: "update", gen: 2}
  #    |> LogWatcher.TaskStarter.new()
  #    |> Oban.insert()

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, term()} | {:discard, term()}
  def perform(%Oban.Job{
        id: id,
        args: %{
          "session_id" => session_id,
          "session_log_path" => session_log_path,
          "task_id" => task_id,
          "task_type" => task_type,
          "gen" => gen_str
        }
      }) do
    Logger.info("job #{id} task_id #{task_id} perform")
    gen = String.to_integer(gen_str)

    Tasks.create_session!(session_id, session_log_path)
    |> watch_and_run(task_id, task_type, gen)
  end

  def perform(%Oban.Job{id: id, args: args}) do
    Logger.error("job #{id} some args are missing: #{inspect(args)}")
    {:discard, "Not a task job"}
  end

  @spec watch_and_run(Session.t(), String.t(), String.t(), integer(), Keyword.t()) ::
          {:ok, term()} | {:discard, term()}
  def watch_and_run(
        %Session{session_id: session_id, session_log_path: session_log_path},
        task_id,
        task_type,
        gen,
        opts \\ []
      ) do
    log_file = Task.log_file_name(task_id, task_type, gen)
    script_file = Keyword.get(opts, :script_file, "mock_task.py")
    executable =
      if String.ends_with?(script_file, ".R") do
        System.find_executable("Rscript")
      else
        System.find_executable("python3")
      end
    if is_nil(executable) do
      raise "no executable found for script file #{script_file}"
    end

    # Set up to receive messages
    Logger.info(
      "job #{task_id}: pid is #{inspect(self())}, start watching #{log_file} in #{
        session_log_path
      }"
    )

    link_result = FileWatcher.start_link_and_watch_file(session_id, session_log_path, log_file)

    Logger.info("job #{task_id}: watcher is #{inspect(link_result)}")

    # Write arg file
    arg_path = Path.join(session_log_path, Task.arg_file_name(task_id, task_type, gen))

    task_arg = %{
      session_id: session_id,
      session_log_path: session_log_path,
      task_id: task_id,
      task_type: task_type,
      gen: gen,
      num_lines: 5 + :rand.uniform(6),
      space_type: "mixture"
    }

    Logger.info("job #{task_id}: write arg file to #{arg_path}")
    :ok = Tasks.write_arg_file(arg_path, task_arg)

    script_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", script_file])

    Logger.info("job #{task_id}: run mock script at #{script_path}")

    # Start mock task script
    script_task =
      Elixir.Task.Supervisor.async_nolink(LogWatcher.TaskSupervisor, fn ->
        run_mock(executable, script_path, session_log_path, session_id, task_id, task_type, gen)
      end)

    # Process incoming messages to find a result
    Logger.info("job #{task_id}: script task ref is #{inspect(script_task.ref)}")
    Logger.info("job #{task_id}: process messages until :task_started is received")
    result = loop(task_id, script_task.ref)

    # Return disposition for Oban
    Logger.info("job #{task_id}: result is #{inspect(result)}")

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
      {:ok, task_info} when is_map(task_info) ->
        {:ok, Map.put(task_info, :script_task, script_task)}

      {:error, reason} ->
        {:discard, reason}
    end
  end

  @spec yield_or_shutdown_task(Elixir.Task.t(), integer()) :: {:ok, term()} | {:error, :timeout}
  def yield_or_shutdown_task(task, timeout) do
    Logger.info("#{inspect(self())} yielding to script task...")
    case Elixir.Task.yield(task, timeout) || Elixir.Task.shutdown(task) do
      {:ok, result} ->
        Logger.info("after yield, script task returned #{inspect(result)}")
        {:ok, result}

      nil ->
        Logger.warn("after yield, failed to get a result from script task in #{timeout}ms")
        {:error, :timeout}
    end
  end

  @spec run_mock(String.t(), String.t(), String.t(), String.t(), String.t(), String.t(), integer()) ::
          :ok | {:error, integer()}
  def run_mock(executable, script_path, session_log_path, session_id, task_id, task_type, gen) do
    Logger.info("job #{task_id}: shelling out to #{executable}")

    {output, exit_status} =
      System.cmd(
        executable,
        [
          script_path,
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
        ],
        cd: Path.dirname(script_path)
      )

    Logger.info("job #{task_id}: script exited with #{exit_status}")
    Logger.info("job #{task_id}: output from script: #{inspect(output)}")

    if exit_status == 0 do
      :ok
    else
      Tasks.session_topic(session_id)
      |> Tasks.broadcast({:script_error, exit_status, output})

      {:error, exit_status}
    end
  end

  @spec loop(String.t(), reference()) :: {:ok, map()} | {:error, :script_terminated | :script_error | :timeout}
  def loop(task_id, task_ref) do
    Logger.info("job #{task_id}: re-entering loop")

    receive do
      {:DOWN, task_ref, :process, pid, reason} ->
        Logger.error("job #{task_id}, loop received :DOWN")
        Logger.info("job #{task_id}, loop returning :error")
        {:error, :script_terminated}

      {:script_error, _exit_status, output} ->
        Logger.error("job #{task_id}, loop received :script_error, output was #{output}")
        Logger.info("job #{task_id}, loop returning :error")
        {:error, :script_error}

      {:task_started, file_name, info} ->
        Logger.info("job #{task_id}, loop received :task_started on #{file_name}")
        Logger.info("job #{task_id}, loop returning :ok #{inspect(info)}")
        {:ok, info}

      {:task_updated, file_name, _info} ->
        Logger.info("job #{task_id}, loop received :task_updated on #{file_name}")
        loop(task_id, task_ref)

      other ->
        Logger.info("job #{task_id}, loop received #{inspect(other)}")
        loop(task_id, task_ref)
    after
      120_000 ->
        Logger.error("job #{task_id}: loop timed out")
        {:error, :timeout}
    end
  end
end
