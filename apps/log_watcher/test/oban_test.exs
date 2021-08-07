defmodule LogWatcher.MockTaskTest do
  use LogWatcher.DataCase, async: false
  use Oban.Testing, repo: LogWatcher.Repo

  alias LogWatcher.{ScriptServer, Tasks, TaskStarter}
  alias LogWatcher.Tasks.Session

  require Logger

  @oban_exec_timeout 30_000
  @script_timeout 30_000

  @tag :start_oban
  test "01 queues and runs an Oban job", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test), script_file: "mock_task.R")

    _ = Tasks.archive_session_tasks(session)

    %{failure: 0, success: 0} = Oban.drain_queue(queue: :tasks)

    {:ok, %Oban.Job{id: job_id, queue: "tasks", state: state}} =
      TaskStarter.insert_job(session, task_id, task_type, task_args)

    _ = Logger.error("inserted new job #{job_id}, state #{state}")

    match_args = %{
      session_id: session.session_id,
      name: session.name,
      description: session.description,
      session_log_path: session.session_log_path,
      gen: session.gen,
      task_id: task_id,
      task_type: task_type,
      task_args: task_args
    }

    assert_enqueued(worker: TaskStarter, args: match_args)

    expiry = System.monotonic_time(:millisecond) + @oban_exec_timeout
    {:ok, info} = wait_for_job_state(job_id, :executing, expiry)
    assert Enum.member?(info.running, job_id)

    # TODO: Get task or os_pid and wait on it
    _ = Logger.error("letting script timeout...")
    _ = Process.sleep(@script_timeout)
  end

  @tag :start_oban
  test "02 runs a mock task under Oban", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test), script_file: "mock_task.R")

    _ = Tasks.archive_session_tasks(session)

    args = %{
      session_id: session.session_id,
      name: session.name,
      description: session.description,
      session_log_path: session.session_log_path,
      gen: session.gen,
      task_id: task_id,
      task_type: task_type,
      task_args: task_args
    }

    start_result = perform_job(LogWatcher.TaskStarter, args)
    task_ref = assert_script_started(start_result, task_id)
    {:ok, _} = wait_on_script_task(task_ref, @script_timeout)
  end

  @tag :start_oban
  test "03 cancels an Oban job", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test), script_file: "mock_task.R")

    _ = Tasks.archive_session_tasks(session)

    {:ok, %Oban.Job{id: job_id, queue: "tasks", state: state}} =
      TaskStarter.insert_job(session, task_id, task_type, task_args)

    _ = Logger.error("inserted new job #{job_id}, state #{state}")

    expiry = System.monotonic_time(:millisecond) + @oban_exec_timeout
    {:ok, info} = wait_for_job_state(job_id, :executing, expiry)
    assert Enum.member?(info.running, job_id)

    _ = Process.sleep(1_000)
    _ = Logger.error("canceling job...")
    :ok = Oban.cancel_job(job_id)
    _ = ScriptServer.cancel_script(job_id)

    {:ok, info} = wait_for_job_state(job_id, :cancelled, expiry)
    # assert Enum.empty?(info.running)

    # TODO: Get task or os_pid and wait on it
    _ = Logger.error("letting script timeout...")
    _ = Process.sleep(@script_timeout)
  end

  @spec wait_for_job_state(String.t(), atom(), integer()) ::
          {:ok, map()} | {:error, atom() | {:timeout, atom()}}
  defp wait_for_job_state(job_id, wait_for_state, expiry) do
    time_now = System.monotonic_time(:millisecond)

    %Oban.Job{state: state_str, queue: "tasks"} = LogWatcher.Repo.get!(Oban.Job, job_id)

    state = String.to_atom(state_str)

    if state == wait_for_state do
      {:ok, Oban.check_queue(queue: :tasks)}
    else
      if time_now <= expiry do
        case state do
          :available ->
            _ = Process.sleep(1_000)
            wait_for_job_state(job_id, wait_for_state, expiry)

          :scheduled ->
            _ = Process.sleep(1_000)
            wait_for_job_state(job_id, wait_for_state, expiry)

          _ ->
            {:error, state}
        end
      else
        {:error, {:timeout, state}}
      end
    end
  end
end
