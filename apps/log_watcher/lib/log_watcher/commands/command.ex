defmodule LogWatcher.Commands.Command do
  @moduledoc """
  Defines a Command struct for use with schemaless changesets.
  Tasks are not stored in a SQL database. Command states are stored and
  maintained in JSON-encoded files.

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

  use TypedStruct

  typedstruct do
    @typedoc "A daptics command constructed from log files"

    plugin(TypedStructEctoChangeset)
    field(:command_id, String.t(), enforce: true)
    field(:session_id, String.t(), enforce: true)
    field(:log_dir, String.t(), enforce: true)
    field(:log_prefix, String.t(), enforce: true)
    field(:command_name, String.t(), enforce: true)
    field(:gen, integer(), enforce: true)
    field(:archived?, boolean(), enforce: true)
    field(:os_pid, integer(), enforce: true)
    field(:status, String.t(), enforce: true)
    field(:created_at, NaiveDateTime.t(), enforce: true)
    field(:updated_at, NaiveDateTime.t(), enforce: true)
    field(:running_at, NaiveDateTime.t())
    field(:completed_at, NaiveDateTime.t())
    field(:progress_counter, integer())
    field(:progress_total, integer())
    field(:progress_phase, String.t())
    field(:last_message, String.t())
    field(:result, term())
    field(:errors, [term()], default: [])
  end

  @spec new() :: t()
  def new() do
    nil_values =
      @enforce_keys
      |> Enum.map(fn key -> {key, nil} end)

    Kernel.struct(__MODULE__, nil_values)
  end

  @spec required_fields([atom()]) :: [atom()]
  def required_fields(fields \\ [])
  def required_fields([]), do: @enforce_keys

  def required_fields(fields) when is_list(fields) do
    @enforce_keys -- @enforce_keys -- fields
  end

  @spec all_fields() :: [atom()]
  def all_fields(), do: Keyword.keys(@changeset_fields)

  @spec changeset_types() :: [{atom(), atom()}]
  def changeset_types(), do: @changeset_fields

  # See https://medium.com/very-big-things/towards-maintainable-elixir-the-core-and-the-interface-c267f0da43
  # for tips on architecting schemaless changesets, input normalization, and contexts.

  # Schema modules usually contain very little logic,
  # mostly an occasional function which returns a value that can be
  # computed from the schema fields (including its associations).

  @spec arg_file_name(String.t(), integer(), String.t(), String.t()) :: String.t()
  def arg_file_name(session_id, gen, command_id, name) do
    "#{make_log_prefix(session_id, gen, command_id, name)}-arg.json"
  end

  @spec arg_file_name(t()) :: String.t()
  def arg_file_name(%__MODULE__{log_prefix: log_prefix}) do
    "#{log_prefix}-arg.json"
  end

  @spec log_file_glob(String.t() | t()) :: String.t()
  def log_file_glob(command_id) when is_binary(command_id) do
    "*#{command_id}-log.json?"
  end

  def log_file_glob(%__MODULE__{command_id: command_id}) do
    "*#{command_id}-log.json?"
  end

  @spec log_file_name(String.t(), integer(), String.t(), String.t(), boolean()) :: String.t()
  def log_file_name(session_id, gen, command_id, name, is_archived \\ false) do
    "#{make_log_prefix(session_id, gen, command_id, name)}-log.#{log_extension(is_archived)}"
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
  def result_file_name(session_id, gen, command_id, name) do
    "#{make_log_prefix(session_id, gen, command_id, name)}-result.json"
  end

  @spec result_file_name(t()) :: String.t()
  def result_file_name(%__MODULE__{log_prefix: log_prefix}) do
    "#{log_prefix}-result.json"
  end

  @spec make_log_prefix(String.t(), integer(), String.t(), String.t()) :: String.t()
  def make_log_prefix(session_id, gen, command_id, name) do
    gen_str = to_string(gen) |> String.pad_leading(4, "0")
    "#{session_id}-#{gen_str}-#{name}-#{command_id}"
  end

  @spec log_extension(boolean()) :: String.t()
  def log_extension(true), do: "jsonx"
  def log_extension(_), do: "jsonl"
end
