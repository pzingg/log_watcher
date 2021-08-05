defmodule LogWatcher.TaskStarter do
  use Oban.Worker, queue: :tasks

  require Logger

  alias LogWatcher.{FileWatcher, Tasks}
  alias LogWatcher.Tasks.{Session, Task}

  defmodule LoopInfo do
    @enforce_keys [:task_id, :job_id, :elixir_task, :cancel_test, :expiry]

    defstruct task_id: nil,
              job_id: 0,
              elixir_task: nil,
              cancel_test: false,
              expiry: 0

    @type t() :: %__MODULE__{
            task_id: String.t(),
            job_id: integer(),
            elixir_task: Elixir.Task.t(),
            cancel_test: boolean(),
            expiry: integer()
          }
  end

  @doc """
  Insert an Oban.Job for this worker.
  """
  @spec insert_job(Session.t(), String.t(), String.t(), map(), Keyword.t()) ::
          {:ok, Oban.Job.t()} | {:error, Oban.Job.changeset()} | {:error, term()}
  def insert_job(session, task_id, task_type, task_args, opts \\ []) do
    result =
      Map.from_struct(session)
      |> Map.merge(%{task_id: task_id, task_type: task_type, task_args: task_args})
      |> __MODULE__.new(opts)
      |> Oban.insert()

    result
  end

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, term()} | {:discard, term()}
  def perform(%Oban.Job{
        id: job_id,
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
    Process.flag(:trap_exit, true)
    Logger.error("perform job #{job_id} task_id #{task_id}")
    Logger.error("worker pid is #{inspect(self())}")

    gen =
      if is_binary(gen_arg) do
        String.to_integer(gen_arg)
      else
        gen_arg
      end

    Tasks.create_session!(session_id, name, description, session_log_path, gen)
    |> watch_and_run(task_id, task_type, Map.put(task_args, "oban_job_id", job_id))
  end

  def perform(%Oban.Job{id: job_id, args: args}) do
    Logger.error("perform job #{job_id} some args are missing: #{inspect(args)}")
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
    Logger.error("watch_and_run")

    log_file = Task.log_file_name(task_id, task_type, gen)
    script_file = Map.fetch!(task_args, "script_file")

    # Set up to receive messages
    job_id = Map.get(task_args, "oban_job_id", 0)
    cancel_test = Map.get(task_args, "cancel_test", false)
    script_timeout = Map.get(task_args, "script_timeout", @default_script_timeout)

    Logger.info(
      "task #{task_id}: job_id #{job_id}, cancel_test #{cancel_test}, pid is #{inspect(self())}"
    )

    Logger.info("task #{task_id}: start watching #{log_file} in #{session_log_path}")

    :ok = Session.events_topic(session_id) |> Session.subscribe()

    {:ok, watcher_pid} =
      FileWatcher.start_link_and_watch_file(session_id, session_log_path, log_file)

    Logger.info("task #{task_id}: watcher is #{inspect(watcher_pid)}")

    # Write arg file
    start_args =
      Map.merge(task_args, %{
        "session_id" => session_id,
        "session_log_path" => session_log_path,
        "task_id" => task_id,
        "task_type" => task_type,
        "gen" => gen
      })
      |> Map.put_new("num_lines", 10)
      |> json_encode_decode(:atoms)

    arg_path = Path.join(session_log_path, Task.arg_file_name(task_id, task_type, gen))
    Logger.info("task #{task_id}: write arg file to #{arg_path}")

    :ok = Tasks.write_arg_file(arg_path, start_args)

    # Start mock task script
    script_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", script_file])
    Logger.info("task #{task_id}: run script at #{script_path}")

    script_task = LogWatcher.ScriptServer.run_script(script_path, start_args)

    # Process incoming messages to find a result
    Logger.info("task #{task_id}: script task ref is #{inspect(script_task.ref)}")
    Logger.error("task #{task_id}: starting loop")

    task_info = %LoopInfo{
      job_id: job_id,
      task_id: task_id,
      elixir_task: script_task,
      cancel_test: cancel_test,
      expiry: System.monotonic_time(:millisecond) + script_timeout
    }

    result = loop(task_info)

    # Return disposition for Oban
    Logger.error("task #{task_id}: exited loop, result is #{inspect(result)}")

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

  @spec loop(LoopInfo.t()) ::
          {:ok, map()}
          | {:error,
             {:EXIT, pid(), atom()}
             | {:script_terminated, term()}
             | {:script_crashed, term()}
             | :timeout}
  @doc """
  Wait for messages from the log watching process.

  Returns `{:ok, result}` if the task entered the running phase without errors.
  The `result` is a map that contains information about the task,
  and `result.script_task` is an Elixir Task struct.

  Returns `{:error, {:EXIT, pid, reason}}` if our process was sent an
  abnormal exit message.

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
  def loop(
        %LoopInfo{
          job_id: job_id,
          task_id: task_id,
          elixir_task: %Elixir.Task{ref: task_ref} = task,
          cancel_test: cancel_test,
          expiry: expiry
        } = info
      ) do
    time_now = System.monotonic_time(:millisecond)
    time_left = max(0, expiry - time_now)

    receive do
      {:task_started, file_name, info} ->
        Logger.info("task #{task_id}, loop received :task_started on #{file_name}")
        result = Map.merge(info, %{script_task: task})
        Logger.info("task #{task_id}, loop returning :ok #{inspect(result)}")
        {:ok, result}

      {:script_terminated, info} ->
        Logger.error("task #{task_id}, loop received :script_terminated, #{inspect(info)}")
        result = Map.merge(info, %{script_task: nil})
        Logger.info("task #{task_id}, loop returning :ok #{inspect(result)}")
        {:ok, result}

      {^task_ref, result} ->
        Logger.error("task #{task_id}, loop received task result for #{inspect(task_ref)}")
        Logger.info("task #{task_id}, loop returning :script_terminated")
        {:error, {:script_terminated, result}}

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        Logger.error("task #{task_id}, loop received :DOWN")
        Logger.info("task #{task_id}, loop returning :script_crashed")
        {:error, {:script_crashed, reason}}

      {:task_updated, file_name, info} ->
        Logger.info("task #{task_id}, loop received :task_updated on #{file_name}")

        {next_info, os_pid} =
          case Map.fetch!(info, :os_pid) do
            0 ->
              {info, 0}

            os_pid ->
              _ = LogWatcher.ScriptServer.update_os_pid(task_ref, os_pid)
              {%LoopInfo{info | cancel_test: false}, os_pid}
          end

        if cancel_test && os_pid != 0 do
          _ = LogWatcher.ScriptServer.cancel_script(job_id)
        end

        Logger.info("task #{task_id}: re-entering loop")
        loop(next_info)

      {:EXIT, pid, reason} ->
        Logger.error("task #{task_id}, loop received :EXIT #{reason}")
        _ = LogWatcher.ScriptServer.cancel_script(job_id)
        {:error, {:EXIT, pid, reason}}

      other ->
        Logger.error("task #{task_id}, loop received #{inspect(other)}")
        Logger.info("task #{task_id}: re-entering loop")
        loop(info)
    after
      time_left ->
        Logger.error("task #{task_id}: loop timed out")
        {:error, :timeout}
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
end
