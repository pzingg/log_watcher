defmodule LogWatcher.Tasks.Task do
  @moduledoc """
  Defines a Task struct for use with schemaless changesets.
  Tasks are not stored in a SQL database.
  """

  defstruct task_id: nil,
            session_id: nil,
            session_log_path: nil,
            log_prefix: nil,
            task_type: nil,
            gen: nil,
            archived?: false,
            os_pid: nil,
            status: nil,
            progress_counter: nil,
            progress_total: nil,
            progress_phase: nil,
            last_message: nil,
            created_at: nil,
            running_at: nil,
            completed_at: nil,
            updated_at: nil,
            result: nil,
            errors: []

  @type t :: %__MODULE__{
          task_id: String.t() | nil,
          session_id: String.t() | nil,
          session_log_path: String.t() | nil,
          log_prefix: String.t() | nil,
          task_type: String.t() | nil,
          gen: integer() | nil,
          archived?: boolean(),
          os_pid: integer() | nil,
          status: String.t() | nil,
          progress_counter: integer() | nil,
          progress_total: integer() | nil,
          progress_phase: String.t() | nil,
          last_message: String.t() | nil,
          created_at: NaiveDateTime.t() | nil,
          running_at: NaiveDateTime.t() | nil,
          completed_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil,
          result: term() | nil,
          errors: [term()]
        }

  # See https://medium.com/very-big-things/towards-maintainable-elixir-the-core-and-the-interface-c267f0da43
  # for tips on architecting schemaless changesets, input normalization, and contexts.

  # Schema modules usually contain very little logic,
  # mostly an occasional function which returns a value that can be
  # computed from the schema fields (including its associations).

  @spec log_extension(boolean()) :: String.t()
  def log_extension(true), do: "jsonx"
  def log_extension(_), do: "jsonl"

  @spec make_log_prefix(String.t(), String.t(), integer()) :: String.t()
  def make_log_prefix(task_id, task_type, gen) do
    gen_str = to_string(gen) |> String.pad_leading(4, "0")
    "#{task_id}-#{task_type}-#{gen_str}"
  end

  @spec log_file_glob(String.t()) :: String.t()
  def log_file_glob(task_id) do
    "#{task_id}-*-log.json?"
  end

  @spec log_file_name(String.t(), String.t(), integer(), boolean()) :: String.t()
  def log_file_name(task_id, task_type, gen, is_archived \\ false) do
    "#{make_log_prefix(task_id, task_type, gen)}-log.#{log_extension(is_archived)}"
  end

  @spec log_file_name(t()) :: String.t()
  def log_file_name(%{log_prefix: log_prefix, archived?: is_archived}) do
    "#{log_prefix}-log.#{log_extension(is_archived)}"
  end

  @spec arg_file_name(t()) :: String.t()
  def arg_file_name(%{log_prefix: log_prefix}) do
    "#{log_prefix}-arg.json"
  end

  @spec start_file_name(t()) :: String.t()
  def start_file_name(%{log_prefix: log_prefix}) do
    "#{log_prefix}-start.json"
  end

  @spec result_file_name(t()) :: String.t()
  def result_file_name(%{log_prefix: log_prefix}) do
    "#{log_prefix}-result.json"
  end
end
