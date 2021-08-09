defmodule LogWatcher.MockTaskTest do
  use LogWatcher.DataCase, async: false
  use Oban.Testing, repo: LogWatcher.Repo

  alias LogWatcher.{ScriptServer, Tasks, TaskStarter}
  alias LogWatcher.Tasks.Session

  @script_timeout 30_000

  test "01 runs an Rscript mock task", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test), script_file: "mock_task.R")

    _ = Tasks.archive_session_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task_ref = assert_script_started(start_result, task_id)
    {:ok, _} = await_task(task_ref, @script_timeout)
  end

  test "02 runs a Python mock task", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test), script_file: "mock_task.py")

    _ = Tasks.archive_session_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task_ref = assert_script_started(start_result, task_id)
    {:ok, _} = await_task(task_ref, @script_timeout)
  end

  test "03 mock task fails in initializing phase", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test),
        script_file: "mock_task.R",
        error: "initializing"
      )

    _ = Tasks.archive_session_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task_ref = assert_script_errors(start_result, task_id, "initializing")
    assert is_nil(task_ref)
  end

  test "04 mock task fails in reading phase", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test),
        script_file: "mock_task.R",
        error: "reading"
      )

    _ = Tasks.archive_session_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task_ref = assert_script_errors(start_result, task_id, "reading")
    {:ok, _} = await_task(task_ref, @script_timeout)
  end

  test "05 mock task fails in started phase", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test),
        script_file: "mock_task.R",
        error: "started"
      )

    _ = Tasks.archive_session_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task_ref = assert_script_errors(start_result, task_id, "started")
    {:ok, _} = await_task(task_ref, @script_timeout)
  end

  test "06 mock task fails in validating phase", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test),
        script_file: "mock_task.R",
        error: "validating"
      )

    _ = Tasks.archive_session_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task_ref = assert_script_errors(start_result, task_id, "validating")
    {:ok, _} = await_task(task_ref, @script_timeout)
  end

  test "07 mock task fails in running phase", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test),
        script_file: "mock_task.R",
        error: "running"
      )

    _ = Tasks.archive_session_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task_ref = assert_script_started(start_result, task_id)
    {:ok, _} = await_task(task_ref, @script_timeout)
  end

  test "08 finds the running task", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test), script_file: "mock_task.R")

    _ = Tasks.archive_session_tasks(session)

    {:ok, %{task_ref: task_ref}} =
      TaskStarter.watch_and_run(session, task_id, task_type, task_args)

    task_list = Tasks.list_tasks(session)
    assert Enum.count(task_list) == 1
    [found_task] = task_list
    assert found_task.task_id == task_id
    assert found_task.task_type == task_type
    assert found_task.gen == session.gen
    assert found_task.status == "running"

    _ = await_task(task_ref, @script_timeout)

    task_list = Tasks.list_tasks(session)
    assert Enum.count(task_list) == 1
    [found_task] = task_list
    assert found_task.status == "completed"

    :ok = Tasks.archive_task!(session, task_id)

    task_list = Tasks.list_tasks(session)
    assert Enum.empty?(task_list)
  end

  test "09 times out on a running task", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test), script_file: "mock_task.R")

    _ = Tasks.archive_session_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task_ref = assert_script_started(start_result, task_id)
    {:error, :timeout} = await_task(task_ref, 500)
    :ok = ScriptServer.kill(task_ref)
  end

  test "10 cancels a mock task", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test),
        script_file: "mock_task.R",
        cancel: "created"
      )

    _ = Tasks.archive_session_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    # Although the last status we read was "created", by the time the script
    # is interrupted, it might be in the "reading" phase.
    task_ref = assert_script_errors(start_result, task_id, ["created", "reading"], "cancelled")
    {:ok, _} = await_task(task_ref, @script_timeout)
  end

  test "11 shuts down a mock task", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      LogWatcher.mock_task_args(to_string(context.test), script_file: "mock_task.R")

    _ = Tasks.archive_session_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task_ref = assert_script_started(start_result, task_id)
    :ok = ScriptServer.kill(task_ref)
  end
end
