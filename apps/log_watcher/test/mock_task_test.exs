defmodule LogWatcher.MockTaskTest do
  use LogWatcher.DataCase, async: false
  use Oban.Testing, repo: LogWatcher.Repo

  alias LogWatcher.{Tasks, TaskStarter}
  alias LogWatcher.Tasks.Session

  test "01 runs a Python mock task" do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args()
    archive_existing_tasks(session)
    result =
      TaskStarter.watch_and_run(session, task_id, task_type, task_args)
      |> wait_on_script_task(30_000)

    {:ok, _info} = result
  end

  test "02 runs an Rscript mock task" do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args()
    archive_existing_tasks(session)
    result =
      TaskStarter.watch_and_run(session, task_id, task_type, task_args, script_file: "mock_task.R")
      |> wait_on_script_task(30_000)

    {:ok, _info} = result
  end

  test "03 runs a failing Rscript mock task" do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args(error: true)
    archive_existing_tasks(session)
    result =
      TaskStarter.watch_and_run(session, task_id, task_type, task_args, script_file: "mock_task.R")
      |> wait_on_script_task(30_000)

    {:discard, {:script_terminated, _}} = result
  end

  test "04 finds an Rscript mock task" do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args()
    archive_existing_tasks(session)
    {:ok, %{script_task: task}} =
      TaskStarter.watch_and_run(session, task_id, task_type, task_args, script_file: "mock_task.R")

    task_list = Tasks.list_tasks(session)
    assert Enum.count(task_list) == 1
    [found_task] = task_list
    assert found_task.task_id == task_id
    assert found_task.task_type == task_type
    assert found_task.gen == session.gen
    assert found_task.status == "running"

    wait_on_script_task(task, 30_000)

    task_list = Tasks.list_tasks(session)
    assert Enum.count(task_list) == 1
    [found_task] = task_list
    assert found_task.status == "completed"

    :ok = Tasks.archive_task!(session, task_id)

    task_list = Tasks.list_tasks(session)
    assert Enum.count(task_list) == 0
  end

  test "05 enqueues an Oban job" do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args(true)
    archive_existing_tasks(session)
    {:ok, %Oban.Job{id: _job_id}} = TaskStarter.work(session, task_id, task_type, task_args)

    match_args = %{
      session_id: session.session_id,
      session_log_path: session.session_log_path,
      gen: session.gen,
      task_id: task_id,
      task_type: task_type,
      task_args: task_args
    }

    assert_enqueued(worker: LogWatcher.TaskStarter, args: match_args)
    assert_enqueued(worker: LogWatcher.TaskStarter, args: match_args)
  end

  test "06 runs a mock task under Oban" do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args(true)
    archive_existing_tasks(session)

    args = %{
      session_id: session.session_id,
      session_log_path: session.session_log_path,
      gen: session.gen,
      task_id: task_id,
      task_type: task_type,
      task_args: task_args
    }
    {:ok, result} = perform_job(LogWatcher.TaskStarter, args)
    assert result.task_id == task_id
    assert String.contains?(result.message, "running on line")

    # wait_task = Elixir.Task.async(fn -> wait_for_os_process(result.os_pid) end)
    # Task.await(wait_task, 30_000)

    {:ok, result}
    |> wait_on_script_task(30_000)
  end

  @spec wait_on_script_task(term(), integer()) :: {:ok, term()} | {:error, :timeout}
  def wait_on_script_task({:ok, %{script_task: %Elixir.Task{} = task}}, timeout) do
    {:ok, TaskStarter.yield_or_shutdown_task(task, timeout)}
  end

  def wait_on_script_task(%Elixir.Task{} = task, timeout) do
    TaskStarter.yield_or_shutdown_task(task, timeout)
  end

  def wait_on_script_task(other, _timeout), do: other

  @spec wait_on_os_process(integer(), integer()) :: :ok | {:error, :timeout}
  def wait_on_os_process(os_pid, timeout) do
    proc_file = "/proc/#{os_pid}"

    if File.exists?(proc_file) do
      expiry = System.monotonic_time() + timeout
      wait_on_proc_file_until(proc_file, expiry)
    else
      :ok
    end
  end

  @spec wait_on_proc_file_until(String.t(), integer()) :: :ok | {:error, :timeout}
  defp wait_on_proc_file_until(proc_file, expiry) do
    now = System.monotonic_time()
    Process.sleep(1)

    if File.exists?(proc_file) do
      if expiry < now do
        {:error, :timeout}
      else
        wait_on_proc_file_until(proc_file, expiry)
      end
    else
      :ok
    end
  end

  defp archive_existing_tasks(session) do
    Tasks.list_task_log_files(session)
    |> Enum.filter(fn %{archived?: archived} -> !archived end)
    |> Enum.map(fn %{task_id: task_id} -> Tasks.archive_task(session, task_id) end)
  end

  defp fake_task_args(opts \\ []) do
    session_id = Faker.Util.format("S%4d")
    session_log_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", "output"])
    gen = :random.uniform(10) - 1
    {:ok, %Session{} = session} = Tasks.create_session(session_id, session_log_path, gen)
    %{
      session: session,
      task_id: Faker.Util.format("T%4d"),
      task_type: Faker.Util.pick(["create", "update", "generate", "analytics"]),
      task_args: %{
        error: Keyword.get(opts, :error, false),
        num_lines: :random.uniform(6) + 6,
        space_type: Faker.Util.pick(["mixture", "factorial", "sparsefactorial"])
      }
    }
  end
end
