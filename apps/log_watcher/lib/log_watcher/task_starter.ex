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
  @doc """
  Create a job and schedule it.
  """
  @spec work(Session.t(), String.t(), String.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Oban.Job.changeset()} | {:error, term()}
  def work(session, task_id, task_type, task_args) do
    result =
      Map.from_struct(session)
      |> Map.merge(%{task_id: task_id, task_type: task_type, task_args: task_args})
      |> LogWatcher.TaskStarter.new()
      |> Oban.insert()

    Logger.info("work result #{inspect(result)}")
    result
  end

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, term()} | {:discard, term()}
  def perform(%Oban.Job{
        id: id,
        args: %{
          "session_id" => session_id,
          "session_log_path" => session_log_path,
          "gen" => gen_arg,
          "task_id" => task_id,
          "task_type" => task_type,
          "task_args" => task_args
        }
      }) do
    Logger.info("job #{id} task_id #{task_id} perform")
    gen =
      if is_binary(gen_arg) do
        String.to_integer(gen_arg)
      else
        gen_arg
      end

    Tasks.create_session!(session_id, session_log_path, gen)
    |> watch_and_run(task_id, task_type, task_args)
  end

  def perform(%Oban.Job{id: id, args: args}) do
    Logger.error("job #{id} some args are missing: #{inspect(args)}")
    {:discard, "Not a task job"}
  end

  @spec watch_and_run(Session.t(), String.t(), String.t(), map(), Keyword.t()) ::
          {:ok, term()} | {:discard, term()}
  def watch_and_run(
        %Session{session_id: session_id, session_log_path: session_log_path, gen: gen},
        task_id,
        task_type,
        task_args,
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

    start_args =
      Map.merge(task_args, %{
        session_id: session_id,
        session_log_path: session_log_path,
        task_id: task_id,
        task_type: task_type,
        gen: gen
      })
      |> Map.put_new(:num_lines, 10)

    Logger.info("job #{task_id}: write arg file to #{arg_path}")
    :ok = Tasks.write_arg_file(arg_path, start_args)

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
    result = loop(task_id, script_task)

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

  @spec run_mock(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          integer()
        ) ::
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

  @spec loop(String.t(), reference()) ::
          {:ok, map()}
          | {:error,
             {:script_terminated, term()}
             | {:script_error, integer()}
             | {:script_crashed, term()}
             | :timeout}
  def loop(task_id, %Elixir.Task{ref: task_ref, pid: task_pid} = task) do
    Logger.info("job #{task_id}: re-entering loop")

    receive do
      {:task_started, file_name, info} ->
        Logger.info("job #{task_id}, loop received :task_started on #{file_name}")
        result =
          Map.merge(info, %{task_ref: task_ref, task_pid: task_pid})
        Logger.info("job #{task_id}, loop returning :ok #{inspect(result)}")
        {:ok, result}

      {^task_ref, task_result} ->
        Logger.error("job #{task_id}, loop received task result for #{inspect(task_ref)}")
        Logger.info("job #{task_id}, loop returning :script_terminated")
        {:error, {:script_terminated, task_result}}

      {:script_error, exit_status, output} ->
        Logger.error(
          "job #{task_id}, loop received :script_error, status #{exit_status} output #{output}"
        )

        Logger.info("job #{task_id}, loop returning :script_error")
        {:error, {:script_error, exit_status}}

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        Logger.error("job #{task_id}, loop received :DOWN")
        Logger.info("job #{task_id}, loop returning :script_crashed")
        {:error, {:script_crashed, reason}}

      {:task_updated, file_name, _info} ->
        Logger.info("job #{task_id}, loop received :task_updated on #{file_name}")
        loop(task_id, task)

      other ->
        Logger.info("job #{task_id}, loop received #{inspect(other)}")
        loop(task_id, task)
    after
      120_000 ->
        Logger.error("job #{task_id}: loop timed out")
        {:error, :timeout}
    end
  end
end
