defmodule LogWatcher do
  @moduledoc """
  LogWatcher keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.

  Collection of utilities in this module.
  """

  alias LogWatcher.{Tasks, TaskStarter}
  alias LogWatcher.Tasks.Session

  ## General utilities

  @doc """
  Format current UTC time as ISO8601 string with millisecond precision.
  """
  @spec format_utcnow() :: String.t()
  def format_utcnow() do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:millisecond)
    |> NaiveDateTime.to_iso8601()
  end

  ## Changeset utilities

  defmodule InputError do
    defexception [:message]

    @impl true
    def exception(message) do
      %__MODULE__{message: message}
    end
  end

  @type normalized_result() :: {:ok, struct()} | {:error, Ecto.Changeset.t()}

  @doc """
  After applying an action to a Changeset, parse the result if it is
  an `{:error, changeset}` tuple, and raise an InputError with a message
  that concatenates all the changeset errors.
  """
  @spec maybe_raise_input_error(normalized_result(), String.t(), atom()) :: struct()
  def maybe_raise_input_error({:error, changeset}, label, id_field) do
    id_value = Ecto.Changeset.get_field(changeset, id_field)
    errors = Translations.changeset_error_messages(changeset) |> Enum.join(" ")

    message =
      if !is_nil(id_value) do
        "#{label} (id: #{id_value}): #{errors}"
      else
        "#{label}: #{errors}"
      end

    raise InputError, message
    InputError.exception(message)
  end

  def maybe_raise_input_error({:ok, data}, _label, _id_field), do: data

  @doc """
  Interpolate the bindings (e.g. `%{count}`) of a Changeset error into
  an error message.
  """
  @spec translate_error_without_gettext({String.t(), Keyword.t()}) :: String.t()
  def translate_error_without_gettext({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  @doc """
  Copied from Phoenix.HTML module. Upcase a field name (either an
  atom or a string), changing underscores to spaces and removing
  any "_id" suffix.
  """
  @spec humanize_field_without_gettext(atom() | binary()) :: String.t()
  def humanize_field_without_gettext(atom) when is_atom(atom),
    do: humanize_field_without_gettext(Atom.to_string(atom))

  def humanize_field_without_gettext(bin) when is_binary(bin) do
    bin =
      if String.ends_with?(bin, "_id") do
        binary_part(bin, 0, byte_size(bin) - 3)
      else
        bin
      end

    bin |> String.replace("_", " ") |> String.capitalize()
  end

  @doc """
  Create a random LogWatcher session and task, and run the task.
  Useful for observing the supervision tree (Hint: use `num_lines: 200`
  to generate a longer running task).
  """
  @spec run_mock_task(String.t(), Keyword.t()) :: {:ok, term()} | {:discard, term()}
  def run_mock_task(description, opts \\ []) do
    %{session: session, task_id: task_id, task_type: task_type, task_args: mock_task_args} =
      mock_task_args(description, script_file: "mock_task.R")

    task_args =
      Enum.reduce(opts, mock_task_args, fn {key, value}, acc ->
        Map.put(acc, to_string(key), value)
      end)

    _ = Tasks.archive_session_tasks(session)

    TaskStarter.watch_and_run(session, task_id, task_type, task_args)
  end

  @doc """
  Create random arguments for a session and task.
  """
  @spec mock_task_args(String.t(), Keyword.t()) :: map()
  def mock_task_args(description, opts) do
    session_id = Faker.Util.format("S%4d")
    session_log_path = Path.join([:code.priv_dir(:log_watcher), "mock_task", "output"])
    gen = :random.uniform(10) - 1
    name = to_string(description) |> String.slice(0..10) |> String.trim()

    {:ok, %Session{} = session} =
      Tasks.create_session(session_id, name, description, session_log_path, gen)

    %{
      session: session,
      task_id: Faker.Util.format("T%4d"),
      task_type: Faker.Util.pick(["create", "update", "generate", "analytics"]),
      task_args: %{
        "script_file" => Keyword.get(opts, :script_file, "mock_task.R"),
        "error" => Keyword.get(opts, :error, ""),
        "cancel" => Keyword.get(opts, :cancel, false),
        "num_lines" => :random.uniform(6) + 6,
        "space_type" => Faker.Util.pick(["mixture", "factorial", "sparsefactorial"])
      }
    }
  end
end
