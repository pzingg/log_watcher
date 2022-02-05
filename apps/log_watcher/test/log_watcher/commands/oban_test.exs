defmodule LogWatcher.Commands.ObanTest do
  use LogWatcher.DataCase, async: false
  use Oban.Testing, repo: LogWatcher.Repo

  alias LogWatcher.CommandJob
  alias LogWatcher.Commands

  require Logger

  @oban_exec_timeout 30_000
  @script_timeout 30_000

  @tag :start_oban
  test "01 runs a command using Oban.Testing perform_job", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } = LogWatcher.mock_command_args(to_string(context.test), script_file: "mock_command.R")

    _ = Commands.archive_session_commands(session)

    args = %{
      session_id: session.id,
      session_name: session.name,
      description: session.description,
      tag: session.tag,
      log_dir: session.log_dir,
      gen: session.gen,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    }

    start_result = perform_job(LogWatcher.CommandJob, args)
    task_ref = assert_script_started(start_result, command_id)

    {:ok, _} = await_task(task_ref, @script_timeout)

    _ = await_pipeline()
  end

  @tag :start_oban
  test "02 queues and runs an Oban job", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } = LogWatcher.mock_command_args(to_string(context.test), script_file: "mock_command.R")

    _ = Commands.archive_session_commands(session)

    %{failure: 0, success: 0} = Oban.drain_queue(CommandJob.queue_opts())

    {:ok, %Oban.Job{id: job_id, queue: queue, state: state}} =
      CommandJob.insert(session, command_id, command_name, command_args)

    _ = Logger.debug("inserted new job #{job_id} on queue #{queue}, state #{state}")

    match_args = %{
      session_id: session.id,
      session_name: session.name,
      description: session.description,
      tag: session.tag,
      log_dir: session.log_dir,
      gen: session.gen,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    }

    assert_enqueued(worker: CommandJob, args: match_args)

    expiry = System.monotonic_time(:millisecond) + @oban_exec_timeout
    {:ok, info} = await_job_state(job_id, :executing, expiry)
    assert Enum.member?(info.running, job_id)

    {:ok, _} = await_task(job_id, @script_timeout)
    info = Oban.check_queue(CommandJob.queue_opts())
    assert Enum.empty?(info.running)

    _ = await_pipeline()
  end

  @tag :start_oban
  test "03 queues, runs and cancels an Oban job", context do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } = LogWatcher.mock_command_args(to_string(context.test), script_file: "mock_command.R")

    _ = Commands.archive_session_commands(session)

    {:ok, %Oban.Job{id: job_id, queue: queue, state: state}} =
      CommandJob.insert(session, command_id, command_name, command_args)

    _ = Logger.debug("inserted new job #{job_id} on queue #{queue}, state #{state}")

    expiry = System.monotonic_time(:millisecond) + @oban_exec_timeout
    {:ok, info} = await_job_state(job_id, :executing, expiry)
    assert Enum.member?(info.running, job_id)

    _ = Process.sleep(1_000)
    _ = Logger.debug("canceling job...")
    :ok = Oban.cancel_job(job_id)

    # Don't do this - it will complete the Oban job.
    # :ok = CommandManager.cancel(job_id)

    {:ok, info} = await_job_state(job_id, :cancelled, expiry)
    assert Enum.member?(info.running, job_id)

    {:ok, _} = await_task(job_id, @script_timeout)
    info = Oban.check_queue(CommandJob.queue_opts())
    assert Enum.empty?(info.running)

    _ = await_pipeline()
  end

  @spec await_job_state(String.t(), atom(), integer()) ::
          {:ok, map()} | {:error, atom() | {:timeout, atom()}}
  defp await_job_state(job_id, wait_for_state, expiry) do
    time_now = System.monotonic_time(:millisecond)

    %Oban.Job{state: state_str} = LogWatcher.Repo.get!(Oban.Job, job_id)
    state = String.to_atom(state_str)

    if state == wait_for_state do
      {:ok, Oban.check_queue(CommandJob.queue_opts())}
    else
      if time_now <= expiry do
        case state do
          :available ->
            _ = Process.sleep(1_000)
            await_job_state(job_id, wait_for_state, expiry)

          :scheduled ->
            _ = Process.sleep(1_000)
            await_job_state(job_id, wait_for_state, expiry)

          _ ->
            {:error, state}
        end
      else
        {:error, {:timeout, state}}
      end
    end
  end
end
