defmodule LogWatcher.Tasks do
  @moduledoc """
  Context for managing tasks, which are started by Oban.Jobs.
  """
  import Ecto.Query

  alias LogWatcher.Repo
  alias LogWatcher.Tasks.{Session, Task}

  require Logger

  ## PubSub utilities
  @spec session_topic(String.t()) :: String.t()
  def session_topic(session_id) do
    "session:#{session_id}"
  end

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic) do
    Logger.info("#{inspect(self())} subscribing to #{topic}")
    Phoenix.PubSub.subscribe(LogWatcher.PubSub, topic)
  end

  @spec broadcast(String.t(), term()) :: :ok | {:error, term()}
  def broadcast(topic, message) when is_tuple(message) do
    Logger.info("#{inspect(self())} broadcasting to #{topic}: #{Kernel.elem(message, 0)}")
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

  ### Sessions on disk

  # See https://medium.com/very-big-things/towards-maintainable-elixir-the-core-and-the-interface-c267f0da43
  # for tips on architecting schemaless changesets, input normalization, and contexts.

  # We don’t keep public changeset functions in the schema module.
  # This approach consolidates the parts which are logically tightly
  # coupled. The changeset building logic is typically needed by a
  # single context function, or occasionally by a couple of related
  # contexts functions (e.g. update and create).

  # Consequently, our schema modules usually contain very little logic,
  # mostly an occasional function which returns a value that can be
  # computed from the schema fields (including its associations).

  # We usually start by keeping the changeset builder code directly
  # in the context function. However, if the logic becomes more complex,
  # or if the changeset builder code needs to be shared between multiple
  # functions, the builder code can be extracted into a separate private
  # function. We avoid creating public changeset builder functions,
  # because this leads to weakly typed abstractions which return overly
  # vague free-form data.

  @doc """
  Create a Session struct object from an id and path.
  """
  @spec create_session!(String.t(), String.t()) :: Session.t()
  def create_session!(session_id, session_log_path) do
    create_session(session_id, session_log_path)
    |> LogWatcher.raise_input_error("Errors reading session", :session_id)
  end

  @spec create_session(String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def create_session(session_id, session_log_path) do
    %{
      "session_id" => session_id,
      "session_log_path" => session_log_path
    }
    |> normalize_session_create_input()
  end

  @session_create_input_schema %{
    session_id: [:string, required: true],
    session_log_path: [:string, required: true]
  }

  @spec normalize_session_create_input(map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  defp normalize_session_create_input(params) do
    {types, permitted_fields, required_fields} =
      LogWatcher.parse_input_types(@session_create_input_schema)

    {%Session{}, types}
    |> Ecto.Changeset.cast(params, permitted_fields)
    |> Ecto.Changeset.validate_required(required_fields)
    |> Ecto.Changeset.apply_action(:insert)
  end

  ### Task files on disk

  @spec list_tasks(Session.t(), boolean()) :: [Task.t()]
  def list_tasks(
        %Session{session_id: session_id, session_log_path: session_log_path},
        include_archived \\ false
      ) do
    glob =
      if include_archived do
        Path.join(session_log_path, "*-log.json?")
      else
        Path.join(session_log_path, "*-log.jsonl")
      end

    glob
    |> Path.wildcard()
    |> Enum.map(&create_task_from_file!(session_id, &1))
  end

  @spec get_task(Session.t(), String.t()) :: Task.t() | nil
  def get_task(%Session{session_id: session_id, session_log_path: session_log_path}, task_id) do
    case list_tag_log_files(session_log_path, task_id) do
      [] ->
        nil

      [file | _] ->
        create_task_from_file!(session_id, file)
    end
  end

  @spec archive_task(Session.t(), String.t()) :: [{String.t(), :ok | {:error, term()}}]
  def archive_task(%Session{session_log_path: session_log_path}, task_id) do
    log_files = list_tag_log_files(session_log_path, task_id)

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
        end
      end)
    end
  end

  @spec create_task_from_file!(String.t(), String.t()) :: Task.t()
  def create_task_from_file!(session_id, log_file_path) do
    create_task_from_file(session_id, log_file_path)
    |> LogWatcher.raise_input_error("Errors reading task", :task_id)
  end

  @spec create_task_from_file(String.t(), String.t()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task_from_file(session_id, log_file_path) do
    session_log_path = Path.dirname(log_file_path)
    log_file_name = Path.basename(log_file_path)
    is_archived = String.ends_with?(log_file_name, ".jsonx")
    log_prefix = Regex.replace(~r/-log\.json.?$/, log_file_name, "")

    with session_and_archive_params <- %{
           "session_id" => session_id,
           "session_log_path" => session_log_path,
           "log_prefix" => log_prefix,
           "archived?" => is_archived
         },
         create_params <-
           Regex.named_captures(
             ~r/^(?<task_id>[^-]+)-(?<task_type>[^-]+)-(?<gen>\d+)/,
             log_file_name
           )
           |> Map.merge(session_and_archive_params),
         # Schemaless changesets
         {:ok, task} <- normalize_task_create_input(create_params),
         status_params <- read_task_status(task) do
      normalize_task_update_status_input(task, status_params)
    end
  end

  @task_create_input_schema %{
    task_id: [:string, required: true],
    session_id: [:string, required: true],
    session_log_path: [:string, required: true],
    log_prefix: [:string, required: true],
    task_type: [:string, required: true],
    gen: [:integer, required: true],
    archived?: [:boolean, required: true]
  }

  @spec normalize_task_create_input(map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  defp normalize_task_create_input(params) do
    {types, permitted_fields, required_fields} =
      LogWatcher.parse_input_types(@task_create_input_schema)

    {%Task{}, types}
    |> Ecto.Changeset.cast(params, permitted_fields)
    |> Ecto.Changeset.validate_required(required_fields)
    |> validate_singleton_task_log_file()
    |> Ecto.Changeset.apply_action(:insert)
  end

  @spec validate_singleton_task_log_file(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_singleton_task_log_file(changeset) do
    session_log_path = Ecto.Changeset.get_change(changeset, :session_log_path)
    task_id = Ecto.Changeset.get_change(changeset, :task_id)
    count = Enum.count(list_tag_log_files(session_log_path, task_id))

    if count == 1 do
      changeset
    else
      changeset
      |> Ecto.Changeset.add_error(
        :session_log_path,
        "%{count} log files exist for #{task_id} in directory",
        count: count
      )
    end
  end

  @spec list_tag_log_files(String.t(), String.t()) :: [String.t()]
  defp list_tag_log_files(session_log_path, task_id) do
    Path.join(session_log_path, Task.log_file_glob(task_id))
    |> Path.wildcard()
  end

  @task_update_status_input_schema %{
    status: [:string, required: true],
    os_pid: :integer,
    progress_counter: :integer,
    progress_total: :integer,
    progress_phase: :string,
    last_message: :string,
    created_at: [:naive_datetime, required: true],
    updated_at: [:naive_datetime, required: true],
    running_at: :naive_datetime,
    completed_at: :naive_datetime,
    result: :map,
    errors: {:array, :map}
  }

  @spec normalize_task_update_status_input(Task.t(), map()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  defp normalize_task_update_status_input(%Task{} = task, params) do
    {types, permitted_fields, required_fields} =
      LogWatcher.parse_input_types(@task_update_status_input_schema)

    {task, types}
    |> Ecto.Changeset.cast(params, permitted_fields)
    |> Ecto.Changeset.cast(params, required_fields)
    |> Ecto.Changeset.apply_action(:update)
  end

  @spec read_task_status(Task.t()) :: map()
  defp read_task_status(%Task{session_log_path: session_log_path} = task) do
    running_at =
      case read_start_info(task) do
        {:ok, info} ->
          info.running_at

        _ ->
          nil
      end

    {completed_at, result, errors} =
      case read_result_info(task) do
        {:ok, info} ->
          {info.completed_at, info.result.data, info.result.errors}

        _ ->
          {nil, nil, []}
      end

    initial_state = %{
      "status" => "undefined",
      "progress_counter" => nil,
      "progress_total" => nil,
      "progress_phase" => nil,
      "last_message" => nil,
      "running_at" => running_at,
      "completed_at" => completed_at,
      "result" => result,
      "errors" => errors
    }

    log_file_path = Path.join(session_log_path, Task.log_file_name(task))

    File.stream!(log_file_path)
    |> Enum.into([])
    |> Enum.reduce(initial_state, fn line, acc ->
      info = Jason.decode!(line, keys: :atoms)
      updated_at = Map.fetch!(info, :time)

      acc
      |> Map.put_new("created_at", updated_at)
      |> Map.put_new("os_pid", Map.fetch!(info, :os_pid))
      |> Map.update!("progress_counter", fn counter ->
        Map.get(info, :progress_counter, counter)
      end)
      |> Map.update!("progress_total", fn total -> Map.get(info, :progress_total, total) end)
      |> Map.update!("progress_phase", fn phase -> Map.get(info, :progress_phase, phase) end)
      |> Map.update!("last_message", fn message -> Map.get(info, :message, message) end)
      |> Map.merge(%{
        "status" => Map.fetch!(info, :status),
        "updated_at" => updated_at
      })
    end)
  end

  @spec write_arg_file(String.t(), map()) :: :ok | {:error, term()}
  def write_arg_file(arg_file_path, arg) do
    with {:ok, content} <- Jason.encode(arg, pretty: [indent: "  "]) do
      File.write(arg_file_path, content)
    end
  end

  @spec read_arg_info(Task.t()) :: {:ok, term()} | {:error, term()}
  defp read_arg_info(%Task{session_log_path: session_log_path} = task) do
    Path.join(session_log_path, Task.arg_file_name(task))
    |> read_json()
  end

  @spec read_start_info(Task.t()) :: {:ok, term()} | {:error, term()}
  defp read_start_info(%Task{session_log_path: session_log_path} = task) do
    Path.join(session_log_path, Task.start_file_name(task))
    |> read_json()
  end

  @spec read_result_info(Task.t()) :: {:ok, term()} | {:error, term()}
  defp read_result_info(%Task{session_log_path: session_log_path} = task) do
    Path.join(session_log_path, Task.result_file_name(task))
    |> read_json()
  end

  @spec read_json(String.t()) :: {:ok, term()} | {:error, term()}
  defp read_json(path) do
    case File.read(path) do
      {:ok, bin} ->
        info = Jason.decode!(bin, keys: :atoms)
        {:ok, info}

      error ->
        error
    end
  end
end
