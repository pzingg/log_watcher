defmodule LogWatcher.Tasks do
  @moduledoc """
  A context for managing Oban jobs, sessions and tasks.
  """
  import Ecto.Query

  alias LogWatcher.Repo
  alias LogWatcher.Tasks.{Session, Task}

  require Logger

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
  @spec create_session!(String.t(), String.t(), String.t(), String.t(), integer()) :: Session.t()
  def create_session!(session_id, name, description, session_log_path, gen) do
    create_session(session_id, name, description, session_log_path, gen)
    |> LogWatcher.maybe_raise_input_error("Errors creating session", :session_id)
  end

  @spec create_session(String.t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, Session.t()} | {:error, term()}
  def create_session(session_id, name, description, session_log_path, gen) do
    %{
      "session_id" => session_id,
      "name" => name,
      "description" => description,
      "session_log_path" => session_log_path,
      "gen" => gen
    }
    |> normalize_session_create_input()
    |> Ecto.Changeset.apply_action(:input)
    |> maybe_init_session_log()
  end

  @spec normalize_session_create_input(map()) :: Ecto.Changeset.t()
  defp normalize_session_create_input(params) do
    fields = [:session_id, :name, :description, :session_log_path, :gen]

    Session.new()
    |> Ecto.Changeset.cast(params, fields)
    |> Ecto.Changeset.validate_required(Session.required_fields(fields))
  end

  defp maybe_init_session_log({:ok, %Session{} = session}) do
    Session.write_event(session, :create_session)
  end

  defp maybe_init_session_log(other), do: other

  @spec update_session(Session.t(), map()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def update_session(session, params) do
    normalize_session_update_input(session, params)
    |> Ecto.Changeset.apply_action(:update)
  end

  @spec normalize_session_update_input(Session.t(), map()) :: Ecto.Changeset.t()
  defp normalize_session_update_input(session, params) do
    fields = [:gen]

    session
    |> Ecto.Changeset.cast(params, fields)
    |> Ecto.Changeset.validate_required(Session.required_fields(fields))
  end

  ### Task files on disk

  @spec list_task_log_files(Session.t(), boolean()) :: [String.t()]
  def list_task_log_files(
        %Session{session_id: session_id, session_log_path: session_log_path},
        include_archived \\ false
      ) do
    log_files_for_session(session_log_path, include_archived)
    |> Enum.map(fn log_file_path ->
      params = parse_log_file_name(session_id, log_file_path)

      %{
        log_file_path: params["log_file_path"],
        log_file_name: params["log_file_name"],
        task_id: params["task_id"],
        task_type: params["task_type"],
        gen: params["gen"],
        archived?: params["archived?"]
      }
    end)
  end

  @spec list_tasks(Session.t(), boolean()) :: [Task.t()]
  def list_tasks(
        %Session{session_id: session_id, session_log_path: session_log_path},
        include_archived \\ false
      ) do
    log_files_for_session(session_log_path, include_archived)
    |> Enum.map(&create_task_from_file!(session_id, &1))
  end

  @spec get_task(Session.t(), String.t()) :: Task.t() | nil
  def get_task(%Session{session_id: session_id, session_log_path: session_log_path}, task_id) do
    case log_files_for_task(session_log_path, task_id) do
      [] ->
        nil

      [file | _] ->
        create_task_from_file!(session_id, file)
    end
  end

  @spec archive_task!(Session.t(), String.t()) :: :ok | {:error, term()}
  def archive_task!(%Session{} = session, task_id) do
    file_results = archive_task(session, task_id)
    count = Enum.count(file_results)

    if count > 1 do
      {:error, "#{count} log files for #{task_id} were archived"}
    else
      [{_task_id_or_file_name, result}] = file_results
      result
    end
  end

  @spec archive_task(Session.t(), String.t()) :: [{String.t(), :ok | {:error, term()}}]
  def archive_task(%Session{session_log_path: session_log_path}, task_id) do
    log_files = log_files_for_task(session_log_path, task_id)

    if Enum.empty?(log_files) do
      [{task_id, {:error, :not_found}}]
    else
      Enum.map(log_files, fn path ->
        file_name = Path.basename(path)

        if String.ends_with?(file_name, "jsonx") do
          {file_name, {:error, :already_archived}}
        else
          archived_path = String.replace_trailing(path, "jsonl", "jsonx")
          {file_name, File.rename(path, archived_path)}
        end
      end)
    end
  end

  @spec create_task_from_file!(String.t(), String.t()) :: Task.t()
  def create_task_from_file!(session_id, log_file_path) do
    create_task_from_file(session_id, log_file_path)
    |> LogWatcher.maybe_raise_input_error("Errors reading task", :task_id)
  end

  @spec create_task_from_file(String.t(), String.t()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task_from_file(session_id, log_file_path) do
    # Schemaless changesets
    with create_params <-
           parse_log_file_name(session_id, log_file_path),
         {:ok, task} <-
           normalize_task_create_input(create_params)
           |> Ecto.Changeset.apply_action(:insert),
         status_params <- read_task_status(task) do
      normalize_task_update_status_input(task, status_params)
      |> Ecto.Changeset.apply_action(:update)
    end
  end

  @spec log_files_for_task(String.t(), String.t()) :: [String.t()]
  defp log_files_for_task(session_log_path, task_id) do
    Path.join(session_log_path, Task.log_file_glob(task_id))
    |> Path.wildcard()
  end

  @spec log_files_for_task(String.t(), boolean()) :: [String.t()]
  defp log_files_for_session(session_log_path, include_archived) do
    Path.join(session_log_path, all_task_log_file_glob(include_archived))
    |> Path.wildcard()
  end

  @spec all_task_log_file_glob(boolean()) :: String.t()
  defp all_task_log_file_glob(false), do: "*-log.jsonl"
  defp all_task_log_file_glob(_), do: "*-log.json?"

  @spec parse_log_file_name(String.t(), String.t()) :: map()
  defp parse_log_file_name(session_id, log_file_path) do
    session_log_path = Path.dirname(log_file_path)
    log_file_name = Path.basename(log_file_path)
    is_archived = String.ends_with?(log_file_name, ".jsonx")
    log_prefix = Regex.replace(~r/-log\.json.?$/, log_file_name, "")

    with session_and_archive_params <- %{
           "session_id" => session_id,
           "session_log_path" => session_log_path,
           "log_file_name" => log_file_name,
           "log_file_path" => log_file_path,
           "log_prefix" => log_prefix,
           "archived?" => is_archived
         },
         file_name_params <-
           Regex.named_captures(
             ~r/^(?<task_id>[^-]+)-(?<task_type>[^-]+)-(?<gen>\d+)/,
             log_file_name
           ) do
      Map.merge(file_name_params, session_and_archive_params)
    end
  end

  @spec normalize_task_create_input(map()) :: Ecto.Changeset.t()
  defp normalize_task_create_input(params) do
    fields = [
      :task_id,
      :session_id,
      :session_log_path,
      :log_prefix,
      :task_type,
      :gen,
      :archived?
    ]

    Task.new()
    |> Ecto.Changeset.cast(params, fields)
    |> Ecto.Changeset.validate_required(Task.required_fields(fields))
    |> validate_singleton_task_log_file()
  end

  @spec validate_singleton_task_log_file(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_singleton_task_log_file(changeset) do
    session_log_path = Ecto.Changeset.get_change(changeset, :session_log_path)
    task_id = Ecto.Changeset.get_change(changeset, :task_id)
    count = Enum.count(log_files_for_task(session_log_path, task_id))

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

  @spec normalize_task_update_status_input(Task.t(), map()) :: Ecto.Changeset.t()
  defp normalize_task_update_status_input(%Task{} = task, params) do
    fields = [
      :status,
      :os_pid,
      :progress_counter,
      :progress_total,
      :progress_phase,
      :last_message,
      :created_at,
      :updated_at,
      :running_at,
      :completed_at,
      :result,
      :errors
    ]

    task
    |> Ecto.Changeset.cast(params, fields)
    |> Ecto.Changeset.validate_required(Task.required_fields(fields))
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
