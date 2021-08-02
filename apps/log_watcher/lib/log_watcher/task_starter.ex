defmodule LogWatcher.TaskStarter do
  use Oban.Worker, queue: :tasks

  require Logger

  alias LogWatcher.{FileWatcher, Tasks}
  alias LogWatcher.Tasks.{Session, Task}

  @info_keys [
    :session_id,
    :session_log_path,
    :task_id,
    :task_type,
    :gen
  ]

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
          "name" => name,
          "description" => description,
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

    Tasks.create_session!(session_id, name, description, session_log_path, gen)
    |> watch_and_run(task_id, task_type, task_args)
  end

  def perform(%Oban.Job{id: id, args: args}) do
    Logger.error("job #{id} some args are missing: #{inspect(args)}")
    {:discard, "Not a task job"}
  end

  @default_script_timeout 120_000

  @doc """
  Note: task_args must have string keys!
  """
  @spec watch_and_run(Session.t(), String.t(), String.t(), map()) ::
          {:ok, term()} | {:discard, term()}
  def watch_and_run(
        %Session{session_id: session_id, session_log_path: session_log_path, gen: gen},
        task_id,
        task_type,
        task_args
      ) do
    log_file = Task.log_file_name(task_id, task_type, gen)
    script_file = Map.fetch!(task_args, "script_file")
    script_timeout = Map.get(task_args, "script_timeout", @default_script_timeout)

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
        "session_id" => session_id,
        "session_log_path" => session_log_path,
        "task_id" => task_id,
        "task_type" => task_type,
        "gen" => gen
      })
      |> Map.put_new("num_lines", 10)

    Logger.info("job #{task_id}: write arg file to #{arg_path}")
    :ok = Tasks.write_arg_file(arg_path, start_args)

    script_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", script_file])

    Logger.info("job #{task_id}: run mock script at #{script_path}")

    # Start mock task script
    script_task =
      Elixir.Task.Supervisor.async_nolink(LogWatcher.TaskSupervisor, fn ->
        run_mock(executable, script_path, start_args)
      end)

    # Process incoming messages to find a result
    Logger.info("job #{task_id}: script task ref is #{inspect(script_task.ref)}")
    Logger.info("job #{task_id}: process messages until :task_started is received")
    expiry = System.monotonic_time(:millisecond) + script_timeout
    result = loop(task_id, script_task, expiry)

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
      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:error, reason} ->
        {:discard, reason}
    end
  end

  @spec yield_or_shutdown_task(Elixir.Task.t(), integer()) ::
          :ok | {:ok, term()} | {:error, :timeout}
  def yield_or_shutdown_task(task, timeout) do
    Logger.info("#{inspect(self())} yielding to script task...")

    case Elixir.Task.yield(task, timeout) || Elixir.Task.shutdown(task) do
      {:ok, :ok} ->
        Logger.info("after yield, script task returned :ok")
        :ok

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
          map()
        ) ::
          :ok | {:error, integer()}
  def run_mock(
        executable,
        script_path,
        %{
          "session_log_path" => session_log_path,
          "session_id" => session_id,
          "task_id" => task_id,
          "task_type" => task_type,
          "gen" => gen
        } = start_args
      ) do
    Logger.info("job #{task_id}: start_args #{inspect(start_args)}")

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
      case {start_args["cancel"], start_args["error"]} do
        {true, _} ->
          ["--cancel" | basic_args]

        {_, ""} ->
          basic_args

        {_, error} when is_binary(error) ->
          basic_args ++ ["--error", error]

        _ ->
          basic_args
      end

    Logger.info("job #{task_id}: shelling out to #{executable} with args #{inspect(script_args)}")

    {output, exit_status} =
      System.cmd(executable, [script_path | script_args], cd: Path.dirname(script_path))

    Logger.info("job #{task_id}: script exited with #{exit_status}")
    Logger.info("job #{task_id}: output from script: #{inspect(output)}")

    info =
      json_encode_decode(start_args, :atoms)
      |> Enum.filter(fn {key, _value} -> Enum.member?(@info_keys, key) end)
      |> Map.new()

    parse_script_output(info, output, exit_status)
  end

  @spec loop(String.t(), Elixir.Task.t(), integer()) ::
          {:ok, map()}
          | {:error,
             {:script_terminated, term()}
             | {:script_crashed, term()}
             | :timeout}
  @doc """
  Wait for messages from the log watching process.

  Returns `{:ok, result}` if the task entered the running phase without errors.
  The `result` is a map that contains information about the task,
  and `result.script_task` is an Elixir Task struct.

  Returns `{:error, {:script_error, exit_status}}` if the shell script called
  by the Elixir Task exited with a non-zero exit status, before it
  entered the start phase.

  Returns `{:error, :script_terminated}` or `
  {:error, {:script_terminated, reason}}` if the Elixir Task ended
  normally before it entered the running phase. `reason` is the value returned
  by the Task.

  Returns `{:error, {:script_crashed, reason}}` if the Elixir Task ended
  abnormally before it entered the running phase. `reason` is the value returned
  by the Task.

  Returns `{:error, :timeout}` if the script never received a "task started"
  message or termination message before the timeout period.
  """
  def loop(task_id, %Elixir.Task{ref: task_ref, pid: _task_pid} = task, expiry) do
    Logger.info("job #{task_id}: re-entering loop")

    time_now = System.monotonic_time(:millisecond)

    time_left =
      if expiry <= time_now do
        0
      else
        expiry - time_now
      end

    receive do
      {:task_started, file_name, info} ->
        Logger.info("job #{task_id}, loop received :task_started on #{file_name}")
        result = Map.merge(info, %{script_task: task})
        Logger.info("job #{task_id}, loop returning :ok #{inspect(result)}")
        {:ok, result}

      {:script_terminated, info} ->
        Logger.error("job #{task_id}, loop received :script_terminated, #{inspect(info)}")
        result = Map.merge(info, %{script_task: nil})
        Logger.info("job #{task_id}, loop returning :ok #{inspect(result)}")
        {:ok, result}

      {^task_ref, result} ->
        Logger.error("job #{task_id}, loop received task result for #{inspect(task_ref)}")
        Logger.info("job #{task_id}, loop returning :script_terminated")
        {:error, {:script_terminated, result}}

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        Logger.error("job #{task_id}, loop received :DOWN")
        Logger.info("job #{task_id}, loop returning :script_crashed")
        {:error, {:script_crashed, reason}}

      {:task_updated, file_name, _info} ->
        Logger.info("job #{task_id}, loop received :task_updated on #{file_name}")
        loop(task_id, task, expiry)

      other ->
        Logger.info("job #{task_id}, loop received #{inspect(other)}")
        loop(task_id, task, expiry)
    after
      time_left ->
        Logger.error("job #{task_id}: loop timed out")
        {:error, :timeout}
    end
  end

  @spec parse_script_output(map(), String.t(), integer()) :: map()
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

    payload
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
end
