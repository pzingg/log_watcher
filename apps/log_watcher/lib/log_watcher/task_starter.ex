defmodule LogWatcher.TaskStarter do
  @moduledoc """
  This module implements the Oban.Worker behaviour, but can be used outside
  of the Oban job processing system. The module is responsible for
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
  use Oban.Worker, queue: :tasks

  require Logger

  alias LogWatcher.{FileWatcherSupervisor, ScriptServer, Sessions, Tasks}
  alias LogWatcher.Sessions.Session
  alias LogWatcher.Tasks.Task

  defmodule LoopInfo do
    @enforce_keys [:expiry, :job_id, :task_id, :task_ref, :cancel]

    defstruct expiry: 0,
              job_id: 0,
              task_id: nil,
              task_ref: nil,
              cancel: nil,
              sent_os_pid: false

    @type t() :: %__MODULE__{
            expiry: integer(),
            job_id: integer(),
            task_id: String.t(),
            task_ref: reference(),
            cancel: String.t(),
            sent_os_pid: boolean()
          }
  end

  defdelegate cancel(key), to: ScriptServer
  defdelegate kill(key), to: ScriptServer
  defdelegate await(key, timeout), to: ScriptServer

  @doc """
  Insert an Oban.Job for this worker.
  """
  @spec insert_job(Session.t(), String.t(), String.t(), map(), Keyword.t()) ::
          {:ok, Oban.Job.t()} | {:error, Oban.Job.changeset()} | {:error, term()}
  def insert_job(session, task_id, task_type, task_args, opts \\ []) do
    result =
      session
      |> Session.to_map()
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
    _ = Process.flag(:trap_exit, true)
    _ = Logger.error("perform job #{job_id} task_id #{task_id}")
    _ = Logger.error("worker pid is #{inspect(self())}")

    gen =
      if is_binary(gen_arg) do
        String.to_integer(gen_arg)
      else
        gen_arg
      end

    session = Sessions.get_session!(session_id)
    watch_and_run(session, task_id, task_type, Map.put(task_args, "oban_job_id", job_id))
  end

  def perform(%Oban.Job{id: job_id, args: args}) do
    _ = Logger.error("perform job #{job_id} some args are missing: #{inspect(args)}")
    {:discard, "Not a task job"}
  end

  @default_script_timeout 120_000

  @doc """
  Note: task_args must have string keys!
  """
  @spec watch_and_run(Session.t(), String.t(), String.t(), map()) ::
          {:ok, term()} | {:discard, term()}
  def watch_and_run(
        %Session{id: session_id, log_path: session_log_path, gen: gen},
        task_id,
        task_type,
        task_args
      ) do
    _ = Logger.error("watch_and_run")

    log_file = Task.log_file_name(session_id, gen, task_id, task_type)
    script_file = Map.fetch!(task_args, "script_file")

    # Set up to receive messages
    job_id = Map.get(task_args, "oban_job_id", 0)
    cancel = Map.get(task_args, "cancel", "none")
    script_timeout = Map.get(task_args, "script_timeout", @default_script_timeout)

    _ =
      Logger.info(
        "task #{task_id}: job_id #{job_id}, cancel #{cancel}, pid is #{inspect(self())}"
      )

    _ = Logger.info("task #{task_id}: start watching #{log_file} in #{session_log_path}")

    :ok = Session.events_topic(session_id) |> Session.subscribe()

    {:ok, watcher_pid} =
      FileWatcherSupervisor.start_child_and_watch_file(session_id, session_log_path, log_file)

    _ = Logger.info("task #{task_id}: watcher is #{inspect(watcher_pid)}")

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

    arg_path =
      Path.join(session_log_path, Task.arg_file_name(session_id, gen, task_id, task_type))

    _ = Logger.info("task #{task_id}: write arg file to #{arg_path}")

    :ok = Tasks.write_arg_file(arg_path, start_args)

    # Start mock task script
    script_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", script_file])
    _ = Logger.info("task #{task_id}: run script at #{script_path}")

    task_ref = ScriptServer.run_script(script_path, start_args)

    # Process incoming messages to find a result
    _ = Logger.info("task #{task_id}: script task ref is #{inspect(task_ref)}")
    _ = Logger.error("task #{task_id}: starting loop")

    task_info = %LoopInfo{
      expiry: System.monotonic_time(:millisecond) + script_timeout,
      job_id: job_id,
      task_id: task_id,
      task_ref: task_ref,
      cancel: cancel
    }

    result = loop(task_info)

    # Return disposition for Oban
    _ = Logger.error("task #{task_id}: exited loop, result is #{inspect(result)}")

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

  Returns `{:ok, result}` if the task entered the running phase without errors.
  The `result` is a map that contains information about the task,
  and `result.task_ref` is a reference to the Elixir Task.

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
          expiry: expiry,
          task_id: task_id,
          task_ref: task_ref
        } = info
      ) do
    time_now = System.monotonic_time(:millisecond)
    time_left = max(0, expiry - time_now)

    receive do
      {:task_started, file_name, info} ->
        _ = Logger.info("task #{task_id}, loop received :task_started on #{file_name}")
        result = Map.merge(info, %{task_ref: task_ref})
        _ = Logger.info("task #{task_id}, loop returning :ok #{inspect(result)}")
        {:ok, result}

      {:script_terminated, info} ->
        _ = Logger.error("task #{task_id}, loop received :script_terminated, #{inspect(info)}")
        result = Map.merge(info, %{task_ref: nil})
        _ = Logger.info("task #{task_id}, loop returning :ok #{inspect(result)}")
        {:ok, result}

      {^task_ref, result} ->
        _ = Logger.error("task #{task_id}, loop received task result for #{inspect(task_ref)}")
        _ = Logger.info("task #{task_id}, loop returning :script_terminated")
        {:error, {:script_terminated, result}}

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        _ = Logger.error("task #{task_id}, loop received :DOWN")
        _ = Logger.info("task #{task_id}, loop returning :script_crashed")
        {:error, {:script_crashed, reason}}

      {:task_updated, file_name, update_info} ->
        _ = Logger.info("task #{task_id}, loop received :task_updated on #{file_name}")

        next_info =
          info
          |> maybe_update_os_pid(update_info)
          |> maybe_cancel(update_info)

        _ = Logger.info("task #{task_id}: re-entering loop")
        loop(next_info)

      {:EXIT, pid, reason} ->
        _ = Logger.error("task #{task_id}, loop received :EXIT #{reason}")
        _ = ScriptServer.cancel(task_ref)
        {:error, {:EXIT, pid, reason}}

      other ->
        _ = Logger.error("task #{task_id}, loop received #{inspect(other)}")
        _ = Logger.info("task #{task_id}: re-entering loop")
        loop(info)
    after
      time_left ->
        _ = Logger.error("task #{task_id}: loop timed out")
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

  @spec maybe_update_os_pid(LoopInfo.t(), map()) :: LoopInfo.t()
  defp maybe_update_os_pid(
         %LoopInfo{task_ref: task_ref, sent_os_pid: sent_os_pid} = info,
         update_info
       ) do
    os_pid = Map.get(update_info, :os_pid, 0)

    if os_pid != 0 && !sent_os_pid do
      _ = ScriptServer.update_os_pid(task_ref, os_pid)
      %LoopInfo{info | sent_os_pid: true}
    else
      info
    end
  end

  @spec maybe_cancel(LoopInfo.t(), map()) :: LoopInfo.t()
  defp maybe_cancel(
         %LoopInfo{task_id: task_id, task_ref: task_ref, cancel: cancel} = info,
         %{status: status}
       ) do
    if status == cancel do
      _ = Logger.error("task #{task_id}: cancelling script, last status read was #{status}")
      _ = ScriptServer.cancel(task_ref)
      %LoopInfo{info | cancel: "sent"}
    else
      info
    end
  end
end
