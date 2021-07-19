defmodule LogWatcher.Tasks do
  @moduledoc """
  Context for managing tasks, which are started by Oban.Jobs.
  """
  import Ecto.Query

  alias LogWatcher.Repo
  alias LogWatcher.Tasks.{Session, Task}

  ## PubSub utilities
  @spec session_topic(String.t()) :: String.t()
  def session_topic(session_id) do
    "session:#{session_id}"
  end

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic) do
    Phoenix.PubSub.subscribe(LogWatcher.PubSub, topic)
  end

  @spec broadcast(String.t(), term()) :: :ok | {:error, term()}
  def broadcast(topic, message) do
    Phoenix.PubSub.broadcast(LogWatcher.PubSub, topic, message)
  end

  ## Oban.Jobs in database
  @spec list_jobs(String.t()) :: [Oban.Job.t()]
  def list_jobs(queue_name \\ "tasks") when is_binary(queue_name) do
    Oban.Job
    |> where([_j], queue: ^queue_name)
    |> Repo.all()
  end

  @spec list_jobs_by_task_id(String.t()) :: [Oban.Job.t()]
  def list_jobs_by_task_id(task_id) when is_binary(task_id) do
    Oban.Job
    |> where([_j], fragment("args->>'task_id' LIKE ?", ^task_id))
    |> Repo.all()
  end

  @spec get_job(integer()) :: Oban.Job.t() | nil
  def get_job(id) when is_integer(id) do
    Oban.Job
    |> where([_j], id: ^id)
    |> Repo.one()
  end

  ## Sessions on disk
  @spec create_session(String.t(), String.t()) :: Session.t()
  def create_session(session_id, session_log_path) do
    Session.changeset(%Session{}, %{
      "session_id" => session_id,
      "session_log_path" => session_log_path})
    |> Ecto.Changeset.apply_changes()
  end

  ## Task files on disk
  @spec list_tasks(Session.t(), boolean()) :: [Task.t()]
  def list_tasks(%Session{session_id: session_id, session_log_path: session_log_path}, include_archived \\ false) do
    glob =
      if include_archived do
        Path.join(session_log_path, "*-log.json?")
      else
        Path.join(session_log_path, "*-log.jsonl")
      end

    glob
    |> Path.wildcard()
    |> Enum.map(&Task.create_from_file!(session_id, &1))
  end

  @spec get_task(Session.t(), String.t()) :: Task.t() | nil
  def get_task(%Session{session_id: session_id, session_log_path: session_log_path}, task_id) do
    case Task.log_files(session_log_path, task_id) do
      [] ->
        nil
      [file | _] ->
        Task.create_from_file!(session_id, file)
    end
  end

  @spec archive_task(Session.t(), String.t()) :: [{String.t(), :ok | {:error, term()}}]
  def archive_task(%Session{session_log_path: session_log_path}, task_id) do
    log_files = Task.log_files(session_log_path, task_id)
    if Enum.empty?(log_files) do
      [{task_id, {:error, :not_found}}]
    else
      Enum.map(log_files, fn path ->
        file = Path.basename(path)
        if String.ends_with?(file, "jsonx") do
          {file, {:error, :already_archived}}
        else
          archived_path = String.replace_trailing(path, "jsonl", "jsonx")
          {file, File.rename(path, archived_path)}
        end end)
    end
  end
end
