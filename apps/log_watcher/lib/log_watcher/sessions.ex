defmodule LogWatcher.Sessions do
  @moduledoc """
  Context module for sessions on disk.
  """

  require Logger

  alias LogWatcher.Repo
  alias LogWatcher.Sessions.{Event, Session}

  # Sessions

  @doc """
  Create a Session struct object from an id and path.
  """
  @spec create_session!(String.t(), String.t(), String.t(), String.t(), integer()) :: Session.t()
  def create_session!(name, description, tag, log_dir, gen) do
    create_session(name, description, tag, log_dir, gen)
    |> LogWatcher.maybe_raise_input_error("Errors creating session", :id)
  end

  @spec create_session(String.t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, Session.t()} | {:error, term()}
  def create_session(name, description, tag, log_dir, gen) do
    attrs = %{
      "name" => name,
      "description" => description,
      "tag" => tag,
      "log_dir" => log_dir,
      "gen" => gen
    }

    case multi_create_session(attrs) |> Repo.transaction() do
      {:ok, %{session: session}} ->
        {:ok, session}

      {:error, :session, changeset, _changes_so_far} ->
        {:error, changeset}

      {:error, _failed_action, reason, _changes_so_far} ->
        {:error, reason}
    end
  end

  @spec get_session!(String.t()) :: Session.t()
  def get_session!(session_id) do
    Repo.get!(Session, session_id)
  end

  @spec update_session(Session.t(), map()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def update_session(session, params) do
    session
    |> Session.update_gen_changeset(params)
    |> Ecto.Changeset.apply_action(:update)
  end

  # Events

  def create_event_from_log_watcher(attrs) do
    Event.log_watcher_changeset(%Event{}, attrs)
    |> Repo.insert()
  end

  # Private functions

  defp multi_create_session(attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:session, Session.changeset(%Session{}, attrs))
    |> Ecto.Multi.run(:validate_path, fn _repo, %{session: session} ->
      if File.dir?(session.log_dir) do
        {:ok, session.log_dir}
      else
        {:error, :enoent}
      end
    end)
    |> Ecto.Multi.run(:write_log, fn _repo, %{session: session} ->
      Session.write_event(session, :create_session)
    end)
  end
end
