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
    field :status, :string
    field :created_at, :naive_datetime
    field :updated_at, :naive_datetime
    field :completed_at, :naive_datetime
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
    status: String.t(),
    created_at: NaiveDateTime.t(),
    updated_at: NaiveDateTime.t(),
    completed_at: NaiveDateTime.t(),
    result: term(),
    errors: [term()]
  }

  def create_from_file_changeset(task, params \\ %{}) do
    task
    |> Ecto.Changeset.cast(params, [
      :session_id,
      :session_log_path,
      :log_prefix,
      :task_id,
      :task_type,
      :gen,
      :archived?
    ])
  end

  # TODO:
  def update_status_changeset(task, params \\ %{}) do
    task
    |> Ecto.Changeset.cast(params, [
      :status,
      :created_at,
      :updated_at,
      :completed_at,
      :result,
      :errors
  ])
  end

  def make_log_prefix(task_id, task_type, gen) do
    gen_str = to_string(gen) |> String.pad_leading(4, "0")
    "#{task_id}-#{task_type}-#{gen_str}"
  end

  def log_extension(true), do: "jsonx"
  def log_extension(_), do: "jsonl"

  def log_file_name(task_id, task_type, gen, is_archived \\ false) do
    "#{make_log_prefix(task_id, task_type, gen)}-log.#{log_extension(is_archived)}"
  end

  def log_file_name(%__MODULE__{log_prefix: log_prefix, archived?: is_archived}) do
    "#{log_prefix}-log.#{log_extension(is_archived)}"
  end

  def start_file_name(%__MODULE__{log_prefix: log_prefix}) do
    "#{log_prefix}-start.json"
  end

  def result_file_name(%__MODULE__{log_prefix: log_prefix}) do
    "#{log_prefix}-result.json"
  end

  def create_from_file(session_id, log_file_path) do
    session_log_path = Path.dirname(log_file_path)
    is_archived = String.ends_with?(session_log_path, ".jsonx")
    log_file_name = Path.basename(log_file_path)
    log_prefix = Regex.replace(~r/-log\.json.?$/, log_file_name, "")

    session_and_archive_params = %{
      "session_id" => session_id,
      "session_log_path" => session_log_path,
      "log_prefix" => log_prefix,
      "archived?" => is_archived
    }

    task_id_params =
      Regex.named_captures(~r/^(?<task_id>[^-]+)-(?<task_type>[^-]+)-(?<gen>\d+)/, log_file_name)

    params =
      task_id_params
      |> Map.merge(session_and_archive_params)

    task =
      create_from_file_changeset(%__MODULE__{}, params)
      |> Ecto.Changeset.apply_changes()

    status_params =
      read_status(task)

    update_status_changeset(task, status_params)
    |> Ecto.Changeset.apply_changes()
  end

  # TODO: get "updated_at" from info["time"], etc.
  def read_status(%__MODULE__{session_log_path: session_log_path} = task) do
    log_file_path = Path.join(session_log_path, log_file_name(task))
    initial_state = %{
      "status" => "undefined",
      "created_at" => nil,
      "updated_at" => nil,
      "completed_at" => nil,
      "result" => nil,
      "errors" => nil
    }
    File.stream!(log_file_path)
    |> Enum.into([])
    |> Enum.reduce(initial_state, fn line, acc ->
      info = Jason.decode!(line, keys: :atoms)
      status = Map.get(info, :status)
      if status do
        Map.put(acc, "status", status)
      else
        acc
      end
    end)
  end

  def read_start_info(%__MODULE__{session_log_path: session_log_path} = task) do
    start_file_path = Path.join(session_log_path, start_file_name(task))
    case File.read(start_file_path) do
      {:ok, bin} ->
        info = Jason.decode!(bin, keys: :atoms)
        {:ok, info}
      error ->
        error
    end
  end
end
