defmodule LogWatcher.MockTaskTest do
  use LogWatcher.DataCase, async: false
  use Oban.Testing, repo: LogWatcher.Repo

  alias LogWatcher.{Tasks, TaskStarter}
  alias LogWatcher.Tasks.Session

  test "runs a Python mock test" do
    session_id = Faker.Util.format("S%4d")
    session_log_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", "output"])
    gen = :random.uniform(10) - 1
    task_id = Faker.Util.format("T%4d")
    task_type = Faker.Util.pick(["create", "update", "generate", "anayltics"])

    task_args = %{
      num_lines: :random.uniform(6) + 6,
      space_type: Faker.Util.pick(["mixture", "factorial", "sparsefactorial"])
    }

    {:ok, %Session{} = session} = Tasks.create_session(session_id, session_log_path, gen)

    result = TaskStarter.watch_and_run(session, task_id, task_type, task_args)

    {:ok, info} = result
    %{script_task: %Elixir.Task{} = script_task} = info
    TaskStarter.yield_or_shutdown_task(script_task, 30_000)
  end

  test "runs an Rscript mock test" do
    session_id = Faker.Util.format("S%4d")
    session_log_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", "output"])
    gen = :random.uniform(10) - 1
    task_id = Faker.Util.format("T%4d")
    task_type = Faker.Util.pick(["create", "update", "generate", "anayltics"])

    task_args = %{
      num_lines: :random.uniform(6) + 6,
      space_type: Faker.Util.pick(["mixture", "factorial", "sparsefactorial"])
    }

    {:ok, %Session{} = session} = Tasks.create_session(session_id, session_log_path, gen)

    result =
      TaskStarter.watch_and_run(session, task_id, task_type, task_args, script_file: "mock_task.R")

    {:ok, info} = result
    %{script_task: %Elixir.Task{} = script_task} = info
    TaskStarter.yield_or_shutdown_task(script_task, 30_000)
  end

  test "enqueues an Oban job" do
    session_id = Faker.Util.format("S%4d")
    session_log_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", "output"])
    gen = :random.uniform(10) - 1
    task_id = Faker.Util.format("T%4d")
    task_type = Faker.Util.pick(["create", "update", "generate", "anayltics"])

    task_args = %{
      num_lines: :random.uniform(6) + 6,
      space_type: Faker.Util.pick(["mixture", "factorial", "sparsefactorial"])
    }

    {:ok, session} = Tasks.create_session(session_id, session_log_path, gen)
    {:ok, %Oban.Job{id: job_id}} = TaskStarter.work(session, task_id, task_type, task_args)

    match_args = %{
      session_id: session_id,
      session_log_path: session_log_path,
      gen: gen,
      task_id: task_id,
      task_type: task_type,
      task_args: task_args
    }
    assert_enqueued([worker: LogWatcher.TaskStarter, args: match_args])
    assert_enqueued([worker: LogWatcher.TaskStarter, args: match_args])
  end

  test "runs a mock test under Oban" do
    session_id = Faker.Util.format("S%4d")
    session_log_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", "output"])
    gen = :random.uniform(10) - 1
    task_id = Faker.Util.format("T%4d")
    task_type = Faker.Util.pick(["create", "update", "generate", "anayltics"])

    task_args = %{
      num_lines: :random.uniform(6) + 6,
      space_type: Faker.Util.pick(["mixture", "factorial", "sparsefactorial"])
    }

    args = %{
      session_id: session_id,
      session_log_path: session_log_path,
      gen: gen,
      task_id: task_id,
      task_type: task_type,
      task_args: task_args
    }
    {:ok, result} = perform_job(LogWatcher.TaskStarter, args)
    assert result.task_id == task_id
    assert String.contains?(result.message, "running on line")
    assert is_pid(result.task_pid)
    assert is_reference(result.task_ref)
    assert is_integer(result.os_pid)

    wait_task = Elixir.Task.async(fn -> wait_for_os_process(result.os_pid) end)
    Task.await(wait_task, 30_000)
  end

  @spec wait_for_os_process(integer()) :: :ok
  def wait_for_os_process(os_pid) do
    if File.exists?("/proc/#{os_pid}") do
      Process.sleep(2)
      wait_for_os_process(os_pid)
    else
      :ok
    end
  end
end
