defmodule LogWatcher.MockTaskTest do
  use LogWatcher.DataCase, async: false
  use Oban.Testing, repo: LogWatcher.Repo

  alias LogWatcher.{Tasks, TaskStarter}
  alias LogWatcher.Tasks.Session

  test "01 runs a Python mock task", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args(context, script_file: "mock_task.py")

    archive_existing_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task = assert_script_started(start_result, task_id)
    {:ok, _} = wait_on_script_task(task, 30_000)
  end

  test "02 runs an Rscript mock task", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args(context, script_file: "mock_task.R")

    archive_existing_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task = assert_script_started(start_result, task_id)
    {:ok, _} = wait_on_script_task(task, 30_000)
  end

  test "03 mock task fails in initializing phase", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args(context, script_file: "mock_task.R", error: "initializing")

    archive_existing_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task = assert_script_errors(start_result, task_id, "initializing")
    assert is_nil(task)
  end

  test "04 mock task fails in reading phase", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args(context, script_file: "mock_task.R", error: "reading")

    archive_existing_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task = assert_script_errors(start_result, task_id, "reading")
    {:ok, _} = wait_on_script_task(task, 30_000)
  end

  test "05 mock task fails in started phase", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args(context, script_file: "mock_task.R", error: "started")

    archive_existing_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task = assert_script_errors(start_result, task_id, "started")
    {:ok, _} = wait_on_script_task(task, 30_000)
  end

  test "06 mock task fails in validating phase", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args(context, script_file: "mock_task.R", error: "validating")

    archive_existing_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task = assert_script_errors(start_result, task_id, "validating")
    {:ok, _} = wait_on_script_task(task, 30_000)
  end

  test "07 mock task fails in running phase", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args(context, script_file: "mock_task.R", error: "running")

    archive_existing_tasks(session)

    start_result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)
    task = assert_script_started(start_result, task_id)
    {:ok, _} = wait_on_script_task(task, 30_000)
  end

  @tag :skip
  test "08 finds the running task", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args(context, script_file: "mock_task.R")

    archive_existing_tasks(session)

    {:ok, %{script_task: task}} =
      TaskStarter.watch_and_run(session, task_id, task_type, task_args)

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
    assert Enum.empty?(task_list)
  end

  test "09 enqueues an Oban job", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args(context, script_file: "mock_task.R")

    archive_existing_tasks(session)

    {:ok, %Oban.Job{id: _job_id}} = TaskStarter.work(session, task_id, task_type, task_args)

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

    assert_enqueued(worker: LogWatcher.TaskStarter, args: match_args)
    assert_enqueued(worker: LogWatcher.TaskStarter, args: match_args)

    # TODO: Get task or os_pid and wait on it
    Process.sleep(5_000)
  end

  test "10 runs a mock task under Oban", context do
    %{session: session, task_id: task_id, task_type: task_type, task_args: task_args} =
      fake_task_args(context, script_file: "mock_task.R")

    archive_existing_tasks(session)

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
    task = assert_script_started(start_result, task_id)
    {:ok, _} = wait_on_script_task(task, 30_000)
  end

  @spec assert_script_started(term(), String.t()) :: {Elixir.Task.t(), [term()]}
  defp assert_script_started(start_result, task_id) do
    {:ok, %{task_id: job_task_id, status: status, message: message, script_task: task}} =
      start_result

    assert job_task_id == task_id
    assert status == "running"
    assert String.contains?(message, "running on line")
    task
  end

  @spec assert_script_errors(term(), String.t(), String.t()) :: {Elixir.Task.t(), [term()]}
  defp assert_script_errors(start_result, task_id, category) do
    {:ok, %{task_id: job_task_id, status: status, message: message, script_task: task} = info} =
      start_result

    assert job_task_id == task_id
    assert status == "completed"
    errors = get_in(info, [:result, :errors])
    assert !is_nil(errors)
    first_error = hd(errors)
    assert !is_nil(first_error)
    assert first_error.category == category
    task
  end

  @spec wait_on_script_task(term(), integer()) :: {:ok, term()} | {:error, :timeout}
  defp wait_on_script_task({:ok, %{script_task: %Elixir.Task{} = task}}, timeout) do
    TaskStarter.yield_or_shutdown_task(task, timeout)
  end

  defp wait_on_script_task(%Elixir.Task{} = task, timeout) do
    TaskStarter.yield_or_shutdown_task(task, timeout)
  end

  defp wait_on_script_task(other, _timeout), do: other

  @spec wait_on_os_process(integer(), integer()) :: :ok | {:error, :timeout}
  defp wait_on_os_process(os_pid, timeout) do
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

  defp fake_task_args(context, opts) do
    session_id = Faker.Util.format("S%4d")
    session_log_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", "output"])
    gen = :random.uniform(10) - 1
    name = to_string(context.test) |> String.slice(0..10) |> String.trim()
    description = to_string(context.test)

    {:ok, %Session{} = session} =
      Tasks.create_session(session_id, name, description, session_log_path, gen)

    %{
      session: session,
      task_id: Faker.Util.format("T%4d"),
      task_type: Faker.Util.pick(["create", "update", "generate", "analytics"]),
      task_args: %{
        "script_file" => Keyword.get(opts, :script_file, "mock_task.R"),
        "error" => Keyword.get(opts, :error, ""),
        "num_lines" => :random.uniform(6) + 6,
        "space_type" => Faker.Util.pick(["mixture", "factorial", "sparsefactorial"])
      }
    }
  end
end
