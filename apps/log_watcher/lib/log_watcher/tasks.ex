defmodule LogWatcher.Tasks do
  @moduledoc """
  Context for managing tasks, which are started by Oban.Jobs.
  """
  import Ecto.Query

  alias LogWatcher.Repo
  alias LogWatcher.Tasks.Task

  ## PubSub utilities
  def session_topic(session_id) do
    "session:#{session_id}"
  end

  def subscribe(topic) do
    Phoenix.PubSub.subscribe(LogWatcher.PubSub, topic)
  end

  def broadcast(topic, message) do
    Phoenix.PubSub.broadcast(LogWatcher.PubSub, topic, message)
  end

  ## Oban.Jobs in database
  def list_jobs(queue_name \\ "tasks") when is_binary(queue_name) do
    Oban.Job
    |> where([_j], queue: ^queue_name)
    |> Repo.all()
  end

  def list_jobs_by_task_id(task_id) when is_binary(task_id) do
    Oban.Job
    |> where([_j], fragment("args->>'task_id' LIKE ?", ^task_id))
    |> Repo.all()
  end

  def get_job(id) when is_integer(id) do
    Oban.Job
    |> where([_j], id: ^id)
    |> Repo.one()
  end

  ## Task files on disk
  def list_tasks(session_id, session_log_path, include_archived \\ false) do
    glob =
      if include_archived do
        Path.join(session_log_path, "*-log.json?")
      else
        Path.join(session_log_path, "*-log.jsonl")
      end

    Path.wildcard(glob)
    |> Enum.map(&Task.create_from_file(session_id, &1))
  end
end
