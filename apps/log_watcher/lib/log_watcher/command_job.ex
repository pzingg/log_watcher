defmodule LogWatcher.CommandJob do
  @moduledoc """
  The Oban worker. The `:commands` queue must also be specified in
  the Oban application configuration.
  """
  use Oban.Worker, queue: :commands

  require Logger

  alias LogWatcher.CommandManager
  alias LogWatcher.Sessions
  alias LogWatcher.Sessions.Session

  # Public interface

  @doc """
  Insert an Oban.Job for this worker.
  """
  @spec insert(Session.t(), String.t(), String.t(), map(), Keyword.t()) ::
          {:ok, Oban.Job.t()} | {:error, Oban.Job.changeset()} | {:error, term()}
  def insert(session, command_id, command_name, command_args, opts \\ []) do
    %{
      session_id: session.id,
      session_name: session.name,
      description: session.description,
      tag: session.tag,
      log_dir: session.log_dir,
      gen: session.gen,
      command_id: command_id,
      command_name: command_name,
      command_args: command_args
    }
    |> __MODULE__.new(opts)
    |> Oban.insert()
  end

  @doc """
  Used for `check_queue`, `drain_queue`, etc.
  """
  @spec queue_opts() :: [{:queue, Oban.queue_name()}]
  def queue_opts(), do: [queue: :commands]

  # Oban.Worker callbacks

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, term()} | {:discard, term()}
  def perform(%Oban.Job{
        id: job_id,
        args: %{
          "session_id" => session_id,
          # "session_name" => session_name,
          # "description" => description,
          # "tag" => tag,
          # "log_dir" => log_dir,
          "gen" => gen_arg,
          "command_id" => command_id,
          "command_name" => command_name,
          "command_args" => command_args
        }
      }) do
    # Trap exits so we terminate if parent dies
    _ = Process.flag(:trap_exit, true)

    _gen =
      if is_binary(gen_arg) do
        String.to_integer(gen_arg)
      else
        gen_arg
      end

    _ = Logger.debug("perform job #{job_id} command_id #{command_id}")
    _ = Logger.debug("worker pid is #{inspect(self())}")

    session = Sessions.get_session!(session_id)

    command_args =
      command_args
      |> LogWatcher.json_encode_decode(:atoms)
      |> Map.put(:oban_job_id, job_id)

    CommandManager.start_script(
      session,
      command_id,
      command_name,
      command_args
    )
  end

  def perform(%Oban.Job{id: job_id, args: args}) do
    _ = Logger.debug("perform job #{job_id} some args are missing: #{inspect(args)}")
    {:discard, "Not a command job"}
  end
end
