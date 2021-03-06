defmodule LogWatcher.Commands.MockTaskTest do
  use LogWatcher.DataCase, async: false
  use Oban.Testing, repo: LogWatcher.Repo

  require Logger

  alias LogWatcher.CommandManager
  alias LogWatcher.Commands

  @script_timeout 30_000

  test "01 runs an Rscript mock command", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } = LogWatcher.mock_command_args(to_string(context.test), script_file: "mock_command.R")

    _ = Commands.archive_session_commands(session)

    Logger.error("Rscript starting")

    start_result = CommandManager.start_script(session, command_id, command_name, command_args)
    task_ref = assert_script_started(start_result, command_id)
    {:ok, _} = await_task(task_ref, @script_timeout)

    Logger.error("Rscript waiting a little for pipeline...")

    _ = await_pipeline()
  end

  test "02 runs a Python mock command", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } = LogWatcher.mock_command_args(to_string(context.test), script_file: "mock_command.py")

    _ = Commands.archive_session_commands(session)

    Logger.error("Python starting")

    start_result = CommandManager.start_script(session, command_id, command_name, command_args)
    task_ref = assert_script_started(start_result, command_id)
    {:ok, _} = await_task(task_ref, @script_timeout)

    Logger.error("Python waiting a little for pipeline...")

    _ = await_pipeline()
  end

  test "03 mock command fails in initializing phase", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } =
      LogWatcher.mock_command_args(to_string(context.test),
        script_file: "mock_command.R",
        error: "initializing"
      )

    _ = Commands.archive_session_commands(session)

    start_result = CommandManager.start_script(session, command_id, command_name, command_args)
    task_ref = assert_script_errors(start_result, command_id, "initializing")
    assert is_nil(task_ref)

    _ = await_pipeline()
  end

  test "04 mock command fails in reading phase", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } =
      LogWatcher.mock_command_args(to_string(context.test),
        script_file: "mock_command.R",
        error: "reading"
      )

    _ = Commands.archive_session_commands(session)

    start_result = CommandManager.start_script(session, command_id, command_name, command_args)

    # nil task_ref returned, it's already gone
    task_ref = assert_script_errors(start_result, command_id, "reading")
    {:ok, _} = await_task(task_ref, @script_timeout)

    _ = await_pipeline()
  end

  test "05 mock command fails in started phase", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } =
      LogWatcher.mock_command_args(to_string(context.test),
        script_file: "mock_command.R",
        error: "started"
      )

    _ = Commands.archive_session_commands(session)

    start_result = CommandManager.start_script(session, command_id, command_name, command_args)

    # nil task_ref returned, it's already gone
    task_ref = assert_script_errors(start_result, command_id, "started")
    {:ok, _} = await_task(task_ref, @script_timeout)

    _ = await_pipeline()
  end

  test "06 mock command fails in validating phase", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } =
      LogWatcher.mock_command_args(to_string(context.test),
        script_file: "mock_command.R",
        error: "validating"
      )

    _ = Commands.archive_session_commands(session)

    start_result = CommandManager.start_script(session, command_id, command_name, command_args)
    task_ref = assert_script_errors(start_result, command_id, "validating")
    {:ok, _} = await_task(task_ref, @script_timeout)

    _ = await_pipeline()
  end

  test "07 mock command fails in running phase", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } =
      LogWatcher.mock_command_args(to_string(context.test),
        script_file: "mock_command.R",
        error: "running"
      )

    _ = Commands.archive_session_commands(session)

    start_result = CommandManager.start_script(session, command_id, command_name, command_args)
    task_ref = assert_script_started(start_result, command_id)
    {:ok, _} = await_task(task_ref, @script_timeout)

    _ = await_pipeline()
  end

  test "08 finds the running command", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } = LogWatcher.mock_command_args(to_string(context.test), script_file: "mock_command.R")

    _ = Commands.archive_session_commands(session)

    {:ok, %{task_ref: task_ref}} =
      CommandManager.start_script(session, command_id, command_name, command_args)

    command_list = Commands.list_commands(session)
    assert Enum.count(command_list) == 1
    [found_command] = command_list
    assert found_command.command_id == command_id
    assert found_command.command_name == command_name
    assert found_command.gen == session.gen
    assert found_command.status == "running"

    {:ok, _} = await_task(task_ref, @script_timeout)

    command_list = Commands.list_commands(session)
    assert Enum.count(command_list) == 1
    [found_command] = command_list
    assert found_command.status == "completed"

    :ok = Commands.archive_command!(session, command_id)

    command_list = Commands.list_commands(session)
    assert Enum.empty?(command_list)

    _ = await_pipeline()
  end

  test "09 times out on a running task", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } = LogWatcher.mock_command_args(to_string(context.test), script_file: "mock_command.R")

    _ = Commands.archive_session_commands(session)

    start_result = CommandManager.start_script(session, command_id, command_name, command_args)
    task_ref = assert_script_started(start_result, command_id)
    {:error, :timeout} = await_task(task_ref, 500)
    :ok = CommandManager.kill(task_ref)

    _ = await_pipeline()
  end

  test "10 cancels a mock command", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } =
      LogWatcher.mock_command_args(to_string(context.test),
        script_file: "mock_command.R",
        num_lines: 50
      )

    _ = Commands.archive_session_commands(session)

    start_result = CommandManager.start_script(session, command_id, command_name, command_args)
    # Although the last status we read was "created", by the time the script
    # is interrupted, it might be in the "reading" phase.

    {:ok, %{task_ref: task_ref}} = start_result
    :ok = CommandManager.cancel(command_id)
    {:ok, result} = await_task(task_ref, @script_timeout)
    assert result.status == "cancelled"

    _ = await_pipeline()
  end

  test "11 shuts down a mock command", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } = LogWatcher.mock_command_args(to_string(context.test), script_file: "mock_command.R")

    _ = Commands.archive_session_commands(session)

    start_result = CommandManager.start_script(session, command_id, command_name, command_args)
    task_ref = assert_script_started(start_result, command_id)
    :ok = CommandManager.kill(task_ref)

    _ = await_pipeline()
  end
end
