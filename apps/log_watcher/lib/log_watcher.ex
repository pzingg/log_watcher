defmodule LogWatcher do
  @moduledoc """
  LogWatcher keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.

  Collection of utilities in this module.
  """

  alias LogWatcher.CommandManager
  alias LogWatcher.Accounts
  alias LogWatcher.Commands
  alias LogWatcher.Sessions

  ## General utilities

  @doc """
  Format current UTC time as ISO8601 string with millisecond precision.
  """
  @spec now() :: String.t()
  def now() do
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
      if is_nil(id_value) do
        "#{label}: #{errors}"
      else
        "#{label} (id: #{id_value}): #{errors}"
      end

    raise InputError, message
    InputError.exception(message)
  end

  def maybe_raise_input_error({:ok, data}, _label, _id_field), do: data

  @script_dir Path.join([:code.priv_dir(:log_watcher), "mock_command"])
  @session_base_dir Path.join([:code.priv_dir(:log_watcher), "mock_command", "sessions"])
  @session_log_dir Path.join([
                     :code.priv_dir(:log_watcher),
                     "mock_command",
                     "sessions",
                     ":tag",
                     "output"
                   ])

  def script_dir() do
    Application.get_env(:log_watcher, :script_dir, @script_dir)
  end

  def session_base_dir() do
    Application.get_env(:log_watcher, :session_base_dir, @session_base_dir)
  end

  def session_log_dir() do
    Application.get_env(:log_watcher, :session_log_dir, @session_log_dir)
  end

  @doc """
  Borrowed from Oban.Testing.
  Converts all atomic keys to strings, and verifies that args are JSON-encodable.
  """
  @spec json_encode_decode(map(), atom()) :: map()
  def json_encode_decode(map, key_type) do
    map
    |> Jason.encode!()
    |> Jason.decode!(keys: key_type)
  end

  @doc """
  Create a random LogWatcher session and command, and run the command.
  Useful for observing the supervision tree (Hint: use `num_lines: 200`
  to generate a longer running command).
  """
  @spec run_mock_command(String.t(), Keyword.t()) :: {:ok, term()} | {:discard, term()}
  def run_mock_command(description, opts \\ []) do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: mock_command_args
    } = mock_command_args(description, script_file: "mock_command.R")

    command_args =
      Enum.reduce(opts, mock_command_args, fn {key, value}, acc ->
        Map.put(acc, to_string(key), value)
      end)

    _ = Commands.archive_session_commands(session)

    CommandManager.start_script(session, command_id, command_name, command_args)
  end

  @doc """
  Create random arguments for a session and command.
  """
  @spec mock_command_args(String.t(), Keyword.t()) :: map()
  def mock_command_args(description, opts) do
    user_id =
      case Keyword.get(opts, :user_id) do
        id when is_binary(id) ->
          id

        _ ->
          {:ok, user} =
            Accounts.create_user(%{
              first_name: Faker.Person.first_name(),
              last_name: Faker.Person.last_name(),
              email: Faker.Internet.email()
            })

          user.id
      end

    :ok = File.mkdir_p(LogWatcher.session_base_dir())

    session_name = to_string(description) |> String.slice(0..10) |> String.trim()

    {:ok, session} =
      Sessions.create_session(%{
        user_id: user_id,
        name: session_name,
        description: description,
        log_dir: LogWatcher.session_log_dir(),
        gen: :rand.uniform(10) - 1
      })

    script_file = Keyword.get(opts, :script_file, "mock_command.R")
    script_path = Path.join(script_dir(), script_file)

    %{
      session: session,
      command_id: Ecto.ULID.generate(),
      command_name: Faker.Util.pick(["create", "update", "generate", "analytics"]),
      command_args: %{
        script_path: script_path,
        error: Keyword.get(opts, :error, ""),
        cancel: Keyword.get(opts, :cancel, ""),
        num_lines: Keyword.get(opts, :num_lines, :rand.uniform(6) + 6),
        space_type: Faker.Util.pick(["mixture", "factorial", "sparsefactorial"])
      }
    }
  end

  @doc """
  Run a script forever, so we can observe the supervision tree.
  """
  def run_mock_command_forever() do
    %{
      session: session,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    } = mock_command_args("Run forever", script_file: "mock_command.R", error: "forever")

    _ = Commands.archive_session_commands(session)

    _start_result = CommandManager.start_script(session, command_id, command_name, command_args)
  end
end
