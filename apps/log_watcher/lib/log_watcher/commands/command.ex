defmodule LogWatcher.Commands.Command do
  @moduledoc """
  Defines a Command struct for use with schemaless changesets.

  Commands are not stored in a SQL database. Instead, command
  states are stored and maintained in JSON-encoded files.

  Each command has a unique ID, the `:command_id` (usually a UUID or ULID).

  A command is perfomed in the context of a session, that is
  the scripts and data files for the command are located in the session
  directory on the file system, and so also has these fields
  that reference the session:

  * `:session_id`
  * `:log_dir`

  Each command has a few required metadata fields specific to an
  implementation for a particular software system:

  * `:command_name` - A string identifying the category of this
    command.
  * `:gen` - An integer used to identify the particular
    invocation of the command.

  The other command fields are updated by reading the log files
  produced by the command.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{
          command_id: String.t(),
          session_id: String.t(),
          log_dir: String.t(),
          log_prefix: String.t(),
          command_name: String.t(),
          gen: integer(),
          archived?: boolean(),
          os_pid: integer(),
          status: String.t(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          running_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          progress_counter: integer() | nil,
          progress_total: integer() | nil,
          progress_phase: String.t() | nil,
          last_message: String.t() | nil,
          result: term() | nil,
          errors: [term()] | nil
        }

  @primary_key false
  embedded_schema do
    field(:command_id, :string, null: false)
    field(:session_id, :string, null: false)
    field(:log_dir, :string, null: false)
    field(:log_prefix, :string, null: false)
    field(:command_name, :string, null: false)
    field(:gen, :integer, null: false, default: -1)
    field(:archived?, :boolean, null: false, default: false)
    field(:os_pid, :integer, null: false, default: 0)
    field(:status, :string, null: false)
    field(:created_at, :utc_datetime, null: false)
    field(:updated_at, :utc_datetime, null: false)
    field(:running_at, :utc_datetime)
    field(:completed_at, :utc_datetime)
    field(:progress_counter, :integer)
    field(:progress_total, :integer)
    field(:progress_phase, :string)
    field(:last_message, :string)
    field(:result, :map)
    field(:errors, {:array, :map}, null: false, default: [])
  end

  def create_changeset(command, params) do
    command
    |> cast(params, [
      :command_id,
      :session_id,
      :log_dir,
      :log_prefix,
      :command_name,
      :gen,
      :archived?
    ])
    |> validate_required([:command_id, :session_id, :log_dir, :log_prefix, :command_name, :gen])
    |> validate_singleton_command_log_file()
  end

  def update_status_changeset(command, params) do
    command
    |> cast(params, [
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
    ])
    |> validate_required([
      :status,
      :last_message,
      :updated_at
    ])
  end

  # See https://medium.com/very-big-things/towards-maintainable-elixir-the-core-and-the-interface-c267f0da43
  # for tips on architecting schemaless changesets, input normalization, and contexts.

  # Schema modules usually contain very little logic,
  # mostly an occasional function which returns a value that can be
  # computed from the schema fields (including its associations).

  @spec arg_file_name(String.t(), integer(), String.t(), String.t()) :: String.t()
  def arg_file_name(session_id, gen, command_id, command_name) do
    "#{make_log_prefix(session_id, gen, command_id, command_name)}-arg.json"
  end

  @spec arg_file_name(t()) :: String.t()
  def arg_file_name(%__MODULE__{log_prefix: log_prefix}) do
    "#{log_prefix}-arg.json"
  end

  @spec log_file_glob(String.t() | t()) :: String.t()
  def log_file_glob(command_id) when is_binary(command_id) do
    "*#{command_id}-log.json?"
  end

  @spec log_file_glob(t()) :: String.t()
  def log_file_glob(%__MODULE__{command_id: command_id}) do
    "*#{command_id}-log.json?"
  end

  @spec all_log_file_glob(boolean()) :: String.t()
  defp all_log_file_glob(false), do: "*-log.jsonl"
  defp all_log_file_glob(_), do: "*-log.json?"

  @spec log_file_name(String.t(), integer(), String.t(), String.t(), boolean()) :: String.t()
  def log_file_name(session_id, gen, command_id, command_name, is_archived \\ false) do
    "#{make_log_prefix(session_id, gen, command_id, command_name)}-log.#{log_extension(is_archived)}"
  end

  @spec log_file_name(t()) :: String.t()
  def log_file_name(%__MODULE__{log_prefix: log_prefix, archived?: is_archived}) do
    "#{log_prefix}-log.#{log_extension(is_archived)}"
  end

  @spec start_file_name(t()) :: String.t()
  def start_file_name(%__MODULE__{log_prefix: log_prefix}) do
    "#{log_prefix}-start.json"
  end

  @spec result_file_name(String.t(), integer(), String.t(), String.t()) :: String.t()
  def result_file_name(session_id, gen, command_id, command_name) do
    "#{make_log_prefix(session_id, gen, command_id, command_name)}-result.json"
  end

  @spec result_file_name(t()) :: String.t()
  def result_file_name(%__MODULE__{log_prefix: log_prefix}) do
    "#{log_prefix}-result.json"
  end

  @spec make_log_prefix(String.t(), integer(), String.t(), String.t()) :: String.t()
  def make_log_prefix(session_id, gen, command_id, command_name) do
    gen_str = to_string(gen) |> String.pad_leading(4, "0")
    "#{session_id}-#{gen_str}-#{command_name}-#{command_id}"
  end

  @spec log_extension(boolean()) :: String.t()
  def log_extension(true), do: "jsonx"
  def log_extension(_), do: "jsonl"

  # Private functions

  @spec validate_singleton_command_log_file(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_singleton_command_log_file(changeset) do
    log_dir = get_change(changeset, :log_dir)
    command_id = get_change(changeset, :command_id)
    count = Enum.count(command_log_files(log_dir, command_id))

    if count == 1 do
      changeset
    else
      add_error(
        changeset,
        :log_dir,
        "%{count} log files exist for #{command_id} in directory",
        count: count
      )
    end
  end

  @spec command_log_files(String.t(), String.t()) :: [String.t()]
  def command_log_files(log_dir, command_id) do
    Path.join(log_dir, log_file_glob(command_id))
    |> Path.wildcard()
  end

  @spec all_log_files(String.t(), boolean()) :: [String.t()]
  def all_log_files(log_dir, include_archived) do
    Path.join(log_dir, all_log_file_glob(include_archived))
    |> Path.wildcard()
  end
end
