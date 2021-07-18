defmodule LogWatcher.Tasks.Task do
  @moduledoc """
  Defines a schema for tasks, not stored in a SQL database.
  """

  use Ecto.Schema

  @primary_key {:task_id, :string, []}
  embedded_schema do
    field :session_id, :string
    field :session_log_path, :string
    field :log_prefix, :string
    field :task_type, :string
    field :gen, :integer
    field :archived?, :boolean
    field :os_pid, :integer
    field :status, :string
    field :progress_counter, :integer
    field :progress_total, :integer
    field :progress_phase, :string
    field :last_message, :string
    field :created_at, :naive_datetime
    field :running_at, :naive_datetime
    field :completed_at, :naive_datetime
    field :updated_at, :naive_datetime
    field :result, :map
    field :errors, {:array, :map}
  end

  @type t :: %__MODULE__{
    session_id: String.t(),
    session_log_path: String.t(),
    log_prefix: String.t(),
    task_id: String.t(),
    task_type: String.t(),
    gen: integer(),
    archived?: boolean(),
    os_pid: integer(),
    status: String.t(),
    progress_counter: integer(),
    progress_total: integer(),
    progress_phase: String.t(),
    last_message: String.t(),
    created_at: NaiveDateTime.t(),
    running_at: NaiveDateTime.t(),
    completed_at: NaiveDateTime.t(),
    updated_at: NaiveDateTime.t(),
    result: term(),
    errors: [term()]
  }

  @create_fields [
    :session_id,
    :session_log_path,
    :log_prefix,
    :task_id,
    :task_type,
    :gen,
    :archived?
  ]

  def create_changeset(task, params \\ %{}) do
    task
    |> Ecto.Changeset.cast(params, @create_fields)
    |> Ecto.Changeset.validate_required(@create_fields)
    |> validate_singleton_log_file()
  end

  def update_changeset(task, params \\ %{}) do
    task
    |> Ecto.Changeset.cast(params, [
      :os_pid,
      :status,
      :progress_counter,
      :progress_total,
      :progress_phase,
      :last_message,
      :created_at,
      :running_at,
      :completed_at,
      :updated_at,
      :result,
      :errors
  ])
  end

  def validate_singleton_log_file(changeset) do
    session_log_path = Ecto.Changeset.get_change(changeset, :session_log_path)
    task_id = Ecto.Changeset.get_change(changeset, :task_id)
    count = Enum.count(log_files(session_log_path, task_id))
    if count == 1 do
      changeset
    else
      changeset
      |> Ecto.Changeset.add_error(:session_log_path,
        "%{count} log files exist for #{task_id} in directory", [count: count])
    end
  end

  def log_extension(true), do: "jsonx"
  def log_extension(_), do: "jsonl"

  def make_log_prefix(task_id, task_type, gen) do
    gen_str = to_string(gen) |> String.pad_leading(4, "0")
    "#{task_id}-#{task_type}-#{gen_str}"
  end

  def log_file_glob(task_id) do
    "#{task_id}-*-log.json?"
  end

  def log_files(session_log_path, task_id) do
    Path.join(session_log_path, log_file_glob(task_id))
    |> Path.wildcard()
  end

  def log_file_name(task_id, task_type, gen, is_archived \\ false) do
    "#{make_log_prefix(task_id, task_type, gen)}-log.#{log_extension(is_archived)}"
  end

  def log_file_name(%__MODULE__{log_prefix: log_prefix, archived?: is_archived}) do
    "#{log_prefix}-log.#{log_extension(is_archived)}"
  end

  def arg_file_name(%__MODULE__{log_prefix: log_prefix}) do
    "#{log_prefix}-arg.json"
  end

  def start_file_name(%__MODULE__{log_prefix: log_prefix}) do
    "#{log_prefix}-start.json"
  end

  def result_file_name(%__MODULE__{log_prefix: log_prefix}) do
    "#{log_prefix}-result.json"
  end

  def create_from_file!(session_id, log_file_path) do
    case create_from_file(session_id, log_file_path) do
      {:ok, task} ->
        task
      {:error, changeset} ->
        message = LogWatcher.error_messages(changeset) |> Enum.join(" ")
        task_id = Ecto.Changeset.get_field(changeset, :task_id)
        raise "errors reading task #{task_id}: #{message}"
    end
  end

  def create_from_file(session_id, log_file_path) do
    session_log_path = Path.dirname(log_file_path)
    log_file_name = Path.basename(log_file_path)
    is_archived = String.ends_with?(log_file_name, ".jsonx")
    log_prefix = Regex.replace(~r/-log\.json.?$/, log_file_name, "")

    session_and_archive_params = %{
      "session_id" => session_id,
      "session_log_path" => session_log_path,
      "log_prefix" => log_prefix,
      "archived?" => is_archived
    }

    create_params =
      Regex.named_captures(~r/^(?<task_id>[^-]+)-(?<task_type>[^-]+)-(?<gen>\d+)/, log_file_name)
      |> Map.merge(session_and_archive_params)
    create_new = create_changeset(%__MODULE__{}, create_params)
    if create_new.valid? do
      task = Ecto.Changeset.apply_changes(create_new)
      status_params = read_status(task)
      update_status = update_changeset(task, status_params)
      if update_status.valid? do
        {:ok, Ecto.Changeset.apply_changes(update_status)}
      else
        {:error, update_status}
      end
    else
      {:error, create_new}
    end
  end

  # TODO: get "updated_at" from info["time"], etc.
  def read_status(%__MODULE__{session_log_path: session_log_path} = task) do
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
      "errors" => errors,
    }

    log_file_path = Path.join(session_log_path, log_file_name(task))
    File.stream!(log_file_path)
    |> Enum.into([])
    |> Enum.reduce(initial_state, fn line, acc ->
      info = Jason.decode!(line, keys: :atoms)
      updated_at = Map.fetch!(info, :time)

      acc
      |> Map.put_new("created_at", updated_at)
      |> Map.put_new("os_pid", Map.fetch!(info, :os_pid))
      |> Map.update!("progress_counter", fn counter -> Map.get(info, :progress_counter, counter) end)
      |> Map.update!("progress_total", fn total -> Map.get(info, :progress_total, total) end)
      |> Map.update!("progress_phase", fn phase -> Map.get(info, :progress_phase, phase) end)
      |> Map.update!("last_message", fn message -> Map.get(info, :message, message) end)
      |> Map.merge(%{
        "status" => Map.fetch!(info, :status),
        "updated_at" => updated_at
      })
    end)
  end

  def read_arg_info(%__MODULE__{session_log_path: session_log_path} = task) do
    Path.join(session_log_path, arg_file_name(task))
    |> read_json()
  end

  def read_start_info(%__MODULE__{session_log_path: session_log_path} = task) do
    Path.join(session_log_path, start_file_name(task))
    |> read_json()
  end

  def read_result_info(%__MODULE__{session_log_path: session_log_path} = task) do
    Path.join(session_log_path, result_file_name(task))
    |> read_json()
  end

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
