defmodule LogWatcher.Commands do
  @moduledoc """
  A context for managing Oban jobs, sessions and commands.
  """
  import Ecto.Query

  alias LogWatcher.Repo
  alias LogWatcher.Sessions.Session
  alias LogWatcher.Commands.Command

  require Logger

  # Oban.Jobs in database

  @spec list_jobs(Oban.queue_name()) :: [Oban.Job.t()]
  def list_jobs(queue \\ :commands)

  def list_jobs(queue) when is_atom(queue), do: list_jobs(Atom.to_string(queue))

  def list_jobs(queue) when is_binary(queue) do
    Oban.Job
    |> where([_j], queue: ^queue)
    |> Repo.all()
  end

  @spec list_jobs_by_command_id(String.t()) :: [Oban.Job.t()]
  def list_jobs_by_command_id(command_id) when is_binary(command_id) do
    Oban.Job
    |> where([_j], fragment("args->>'command_id' LIKE ?", ^command_id))
    |> Repo.all()
  end

  @spec get_job(integer()) :: Oban.Job.t() | nil
  def get_job(id) when is_integer(id) do
    Oban.Job
    |> where([_j], id: ^id)
    |> Repo.one()
  end

  ### Command files on disk

  @spec archive_session_commands(Session.t()) :: [{String.t(), :ok | {:error, term()}}]
  def archive_session_commands(%Session{} = session) do
    list_command_log_files(session, false)
    |> Enum.map(fn command_id -> archive_command(session, command_id) end)
    |> List.flatten()
  end

  @spec list_command_log_files(Session.t(), boolean()) :: [String.t()]
  def list_command_log_files(
        %Session{id: session_id, log_dir: log_dir},
        include_archived \\ false
      ) do
    log_files_for_session(log_dir, include_archived)
    |> Enum.map(fn log_file_path ->
      parse_log_file_name(session_id, log_file_path) |> Map.get("command_id")
    end)
  end

  @spec list_commands(Session.t(), boolean()) :: [Command.t()]
  def list_commands(
        %Session{id: session_id, log_dir: log_dir},
        include_archived \\ false
      ) do
    log_files_for_session(log_dir, include_archived)
    |> Enum.map(&create_command_from_file!(session_id, &1))
  end

  @spec get_command(Session.t(), String.t()) :: Command.t() | nil
  def get_command(%Session{id: session_id, log_dir: log_dir}, command_id) do
    case log_files_for_command(log_dir, command_id) do
      [] ->
        nil

      [file | _] ->
        create_command_from_file!(session_id, file)
    end
  end

  @spec archive_command!(Session.t(), String.t()) :: :ok | {:error, term()}
  def archive_command!(%Session{} = session, command_id) do
    file_results = archive_command(session, command_id)
    count = Enum.count(file_results)

    if count > 1 do
      {:error, "#{count} log files for #{command_id} were archived"}
    else
      [{_command_id_or_file_name, result}] = file_results
      result
    end
  end

  @spec archive_command(Session.t(), String.t()) :: [{String.t(), :ok | {:error, term()}}]
  def archive_command(%Session{log_dir: log_dir}, command_id) do
    log_files = log_files_for_command(log_dir, command_id)

    if Enum.empty?(log_files) do
      [{command_id, {:error, :not_found}}]
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

  @spec create_command_from_file!(String.t(), String.t()) :: Command.t()
  def create_command_from_file!(session_id, log_file_path) do
    create_command_from_file(session_id, log_file_path)
    |> LogWatcher.maybe_raise_input_error("Errors reading command", :command_id)
  end

  @spec create_command_from_file(String.t(), String.t()) ::
          {:ok, Command.t()} | {:error, Ecto.Changeset.t()}
  def create_command_from_file(session_id, log_file_path) do
    # Schemaless changesets
    with create_params <-
           parse_log_file_name(session_id, log_file_path),
         {:ok, command} <-
           normalize_command_create_input(create_params)
           |> Ecto.Changeset.apply_action(:insert),
         status_params <- read_command_status(command) do
      normalize_command_update_status_input(command, status_params)
      |> Ecto.Changeset.apply_action(:update)
    end
  end

  @spec log_files_for_command(String.t(), String.t()) :: [String.t()]
  defp log_files_for_command(log_dir, command_id) do
    Path.join(log_dir, Command.log_file_glob(command_id))
    |> Path.wildcard()
  end

  @spec log_files_for_command(String.t(), boolean()) :: [String.t()]
  defp log_files_for_session(log_dir, include_archived) do
    Path.join(log_dir, all_command_log_file_glob(include_archived))
    |> Path.wildcard()
  end

  @spec all_command_log_file_glob(boolean()) :: String.t()
  defp all_command_log_file_glob(false), do: "*-log.jsonl"
  defp all_command_log_file_glob(_), do: "*-log.json?"

  @spec parse_log_file_name(String.t(), String.t()) :: map()
  defp parse_log_file_name(session_id, log_file_path) do
    log_dir = Path.dirname(log_file_path)
    log_file_name = Path.basename(log_file_path)
    is_archived = String.ends_with?(log_file_name, ".jsonx")
    log_prefix = Regex.replace(~r/-log\.json.?$/, log_file_name, "")

    with session_and_archive_params <- %{
           "log_dir" => log_dir,
           "log_file_name" => log_file_name,
           "log_file_path" => log_file_path,
           "log_prefix" => log_prefix,
           "archived?" => is_archived
         },
         file_name_params <-
           Regex.named_captures(
             ~r/^(?<session_id>[^-]+)-(?<gen>\d+)-(?<command_name>[^-]+)-(?<command_id>[^-]+)/,
             log_file_name
           ) do
      if !is_map(file_name_params) do
        raise "Bad log file name #{log_file_name}"
      end

      params =
        if file_name_params["session_id"] != session_id do
          _ = Logger.debug("session_id in log file name does not match session")
          Map.put(file_name_params, "session_id", session_id)
        else
          file_name_params
        end

      Map.merge(params, session_and_archive_params)
    end
  end

  @spec normalize_command_create_input(map()) :: Ecto.Changeset.t()
  defp normalize_command_create_input(params) do
    fields = [
      :command_id,
      :session_id,
      :log_dir,
      :log_prefix,
      :command_name,
      :gen,
      :archived?
    ]

    Command.new()
    |> Ecto.Changeset.cast(params, fields)
    |> Ecto.Changeset.validate_required(Command.required_fields(fields))
    |> validate_singleton_command_log_file()
  end

  @spec validate_singleton_command_log_file(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_singleton_command_log_file(changeset) do
    log_dir = Ecto.Changeset.get_change(changeset, :log_dir)
    command_id = Ecto.Changeset.get_change(changeset, :command_id)
    count = Enum.count(log_files_for_command(log_dir, command_id))

    if count == 1 do
      changeset
    else
      changeset
      |> Ecto.Changeset.add_error(
        :log_dir,
        "%{count} log files exist for #{command_id} in directory",
        count: count
      )
    end
  end

  @spec normalize_command_update_status_input(Command.t(), map()) :: Ecto.Changeset.t()
  defp normalize_command_update_status_input(%Command{} = command, params) do
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

    command
    |> Ecto.Changeset.cast(params, fields)
    |> Ecto.Changeset.validate_required(Command.required_fields(fields))
  end

  @spec read_command_status(Command.t()) :: map()
  defp read_command_status(%Command{log_dir: log_dir} = command) do
    running_at =
      case read_start_info(command) do
        {:ok, info} ->
          info.running_at

        _ ->
          nil
      end

    {completed_at, result, errors} =
      case read_result_info(command) do
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

    log_file_path = Path.join(log_dir, Command.log_file_name(command))

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

  @spec read_arg_info(Command.t()) :: {:ok, term()} | {:error, term()}
  defp read_arg_info(%Command{log_dir: log_dir} = command) do
    Path.join(log_dir, Command.arg_file_name(command))
    |> read_json()
  end

  @spec read_start_info(Command.t()) :: {:ok, term()} | {:error, term()}
  defp read_start_info(%Command{log_dir: log_dir} = command) do
    Path.join(log_dir, Command.start_file_name(command))
    |> read_json()
  end

  @spec read_result_info(Command.t()) :: {:ok, term()} | {:error, term()}
  defp read_result_info(%Command{log_dir: log_dir} = command) do
    Path.join(log_dir, Command.result_file_name(command))
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
