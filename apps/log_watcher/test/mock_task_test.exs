defmodule LogWatcher.MockTaskTest do
  use LogWatcher.DataCase, async: false

  alias LogWatcher.{Tasks, TaskStarter}
  alias LogWatcher.Tasks.Session

  @tag :skip
  test "runs a Python mock test" do
    session_id = Faker.Util.format("S%4d")
    task_id = Faker.Util.format("T%4d")
    task_type = Faker.Util.pick(["create", "update", "generate", "anayltics"])
    gen = :random.uniform(10) - 1

    session_log_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", "output"])
    {:ok, %Session{} = session} = Tasks.create_session(session_id, session_log_path)

    result = TaskStarter.watch_and_run(session, task_id, task_type, gen)

    {:ok, info} = result
    %{script_task: %Elixir.Task{} = script_task} = info
    TaskStarter.yield_or_shutdown_task(script_task, 30_000)
  end

  test "runs an Rscript mock test" do
    session_id = Faker.Util.format("S%4d")
    task_id = Faker.Util.format("T%4d")
    task_type = Faker.Util.pick(["create", "update", "generate", "anayltics"])
    gen = :random.uniform(10) - 1

    session_log_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", "output"])
    {:ok, %Session{} = session} = Tasks.create_session(session_id, session_log_path)
    result = TaskStarter.watch_and_run(session, task_id, task_type, gen, script_file: "mock_task.R")

    {:ok, info} = result
    %{script_task: %Elixir.Task{} = script_task} = info
    TaskStarter.yield_or_shutdown_task(script_task, 30_000)
  end

  @tag :skip
  test "runs a mock test under Oban" do
    session_id = Faker.Util.format("S%4d")
    task_id = Faker.Util.format("T%4d")
    task_type = Faker.Util.pick(["create", "update", "generate", "anayltics"])
    gen = :random.uniform(10) - 1

    session_log_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", "output"])
    {:ok, %Session{} = session} = Tasks.create_session(session_id, session_log_path)

    job_args = %{
      id: 100,
      session_id: session_id,
      session_log_path: session_log_path,
      task_id: task_id,
      task_type: task_type,
      gen: gen
    }

    job_args
    |> LogWatcher.TaskStarter.new()

    #  |> Oban.insert()
  end
end
