defmodule LogWatcher.TaskStarter do
  use Oban.Worker, queue: :tasks

  require Logger

  alias LogWatcher.Tasks
  alias LogWatcher.Tasks.Task

  # To start a job
  # %{id: 100, task_type: "update", gen: 2} |> LogWatcher.LogWatcherWorker.new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"task_id" => task_id, "task_type" => task_type, "gen" => gen}}) do
    Logger.info("job #{id} task_id #{task_id} perform")
    session_log_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", "output"])
    watch_and_run("S1", session_log_path, task_id, task_type, gen)
  end

  def perform(%Oban.Job{id: id, args: args}) do
    Logger.error("job #{id} some args are missing: #{inspect(args)}")
    {:error, "Not a task job"}
  end

  def watch_and_run(session_id, session_log_path, task_id, task_type, gen) do
    log_file = Task.log_file_name(task_id, task_type, gen)
    Logger.info("job #{task_id}: pid is #{inspect(self())}, start watching #{log_file}")

    Tasks.session_topic(session_id)
    |> Tasks.subscribe()

    _watcher_pid =
      case LogWatcher.FileWatcher.start_link(session_id, session_log_path) do
        {:ok, pid} ->
          pid
        {:error, {:already_started, pid}} ->
          pid
        _other ->
          :ignore
      end
    {:ok, _file} = LogWatcher.FileWatcher.add_watch(session_id, log_file)

    length = 15
    cmd_dir = Path.join(:code.priv_dir(:log_watcher), "mock_task")
    task_script = Path.join(cmd_dir, "mock_task.py")
    log_path = Path.join(session_log_path, log_file)
    Logger.info("job #{task_id}: shelling out to #{task_script}")

    _pid = spawn(fn ->
      {output, exit_status} = System.cmd("python3", [task_script,
        "--log-path", log_path,
        "--session-id", session_id,
        "--task-id", task_id,
        "--task-type", task_type,
        "--gen", to_string(gen),
        "--length", to_string(length)], cd: cmd_dir)
      Logger.info("job #{task_id}: script exited with #{exit_status}")
      Logger.info("job #{task_id}: output from script: #{inspect(output)}")
    end)

    result = loop(task_id)
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
      {:ok, task_info} ->
        Tasks.session_topic(session_id)
        |> Tasks.broadcast({:task_started, task_info})
        {:ok, task_info}
      {:error, reason} ->
        {:discard, reason}
    end
  end

  def loop(task_id) do
    Logger.info("job #{task_id}: re-entering loop")
    receive do
      {:task_started, file_name, info} ->
        Logger.info("job #{task_id}, loop received :task_started on #{file_name}")
        Logger.info("job #{task_id}, loop returning :ok #{inspect(info)}")
        {:ok, info}
      {:task_updated, file_name, _info} ->
        Logger.info("job #{task_id}, loop received :task_updated on #{file_name}")
        loop(task_id)
      {:task_file_closed, file_name} ->
        Logger.error("job #{task_id}, loop received :task_file_closed on #{file_name}")
        Logger.info("job #{task_id}, loop returning :error")
        {:error, :unexpected_close}
      other ->
        Logger.info("job #{task_id}, loop received #{inspect(other)}")
        loop(task_id)
    after
      120_000 ->
        Logger.error("job #{task_id}: loop timed out")
        {:error, :timeout}
    end
  end
end
