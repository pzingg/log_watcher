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
    Command.all_log_files(log_dir, include_archived)
    |> Enum.map(fn log_file_path ->
      parse_log_file_name(session_id, log_file_path) |> Map.get("command_id")
    end)
  end

  @spec list_commands(Session.t(), boolean()) :: [Command.t()]
  def list_commands(
        %Session{id: session_id, log_dir: log_dir},
        include_archived \\ false
      ) do
    Command.all_log_files(log_dir, include_archived)
    |> Enum.map(&create_command_from_file!(session_id, &1))
  end

  @spec get_command(Session.t(), String.t()) :: Command.t() | nil
  def get_command(%Session{id: session_id, log_dir: log_dir}, command_id) do
    case Command.command_log_files(log_dir, command_id) do
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
    log_files = Command.command_log_files(log_dir, command_id)

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
    with {:ok, create_params} <-
           parse_log_file_name(session_id, log_file_path),
         {:ok, command} <-
           change_create_command(%Command{}, create_params)
           |> Ecto.Changeset.apply_action(:insert),
         status_params <- read_command_status(command) do
      change_update_command_status(command, status_params)
      |> Ecto.Changeset.apply_action(:update)
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking initial command changes.

  ## Examples

      iex> change_create_command(command)
      %Ecto.Changeset{data: %Command{}}

  """
  def change_create_command(%Command{} = command, attrs \\ %{}) do
    Command.create_changeset(command, attrs)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking command status changes.

  ## Examples

      iex> change_update_command_status(command)
      %Ecto.Changeset{data: %Command{}}

  """
  def change_update_command_status(%Command{} = command, attrs \\ %{}) do
    Command.update_status_changeset(command, attrs)
  end

  # Private functions

  defp parse_params(log_file_name) do
    case Regex.named_captures(
           ~r/^(?<session_id>[^-]+)-(?<gen>\d+)-(?<command_name>[^-]+)-(?<command_id>[^-]+)/,
           log_file_name
         ) do
      nil ->
        {:error, :invalid_file_name}

      params ->
        valid_params? =
          ["session_id", "gen", "command_name", "command_id"]
          |> Enum.all?(fn key -> params[key] != "" end)

        if valid_params? do
          {:ok, params}
        else
          {:error, :invalid_file_name}
        end
    end
  end

  @spec parse_log_file_name(String.t(), String.t()) :: map()
  defp parse_log_file_name(session_id, log_file_path) do
    log_file_name = Path.basename(log_file_path)

    case parse_params(log_file_name) do
      {:ok, params} ->
        params =
          if params["session_id"] != session_id do
            _ = Logger.warn("session_id in log file name does not match session")
            Map.put(params, "session_id", session_id)
          else
            params
          end

        log_dir = Path.dirname(log_file_path)
        log_prefix = Regex.replace(~r/-log\.json.?$/, log_file_name, "")
        is_archived = String.ends_with?(log_file_name, ".jsonx")

        {:ok,
         Map.merge(params, %{
           "log_dir" => log_dir,
           "log_file_name" => log_file_name,
           "log_file_path" => log_file_path,
           "log_prefix" => log_prefix,
           "archived?" => is_archived
         })}

      error ->
        error
    end
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
