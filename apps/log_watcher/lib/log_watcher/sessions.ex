defmodule LogWatcher.Sessions do
  @moduledoc """
  The Sessions context.
  """
  import Ecto.Query, warn: false

  require Logger

  alias LogWatcher.Repo
  alias LogWatcher.Accounts.User
  alias LogWatcher.Sessions.Event
  alias LogWatcher.Sessions.Session

  # Sessions

  @doc """
  Returns the list of sessions.

  ## Examples

      iex> list_sessions()
      [%Session{}, ...]

  """
  def list_sessions() do
    Repo.all(Session)
  end

  @doc """
  Returns the list of sessions for a given user.

  ## Examples

      iex> list_sessions_for_user(user)
      [%Session{}, ...]

  """
  def list_sessions_for_user(user) do
    user_sessions_query(user)
    |> Repo.all()
  end

  def user_sessions_query(user) do
    from(s in Session, where: s.user_id == ^user.id)
  end

  @doc """
  Gets a single session.

  Raises `Ecto.NoResultsError` if the Session does not exist.

  ## Examples

      iex> get_session!(123)
      %Session{}

      iex> get_session!(456)
      ** (Ecto.NoResultsError)

  """
  def get_session!(id) do
    Repo.get!(Session, id)
  end

  @doc """
  Creates a session.

  ## Examples

      iex> create_session(%{field: value})
      {:ok, %Session{}}

      iex> create_session(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_session(map()) :: {:ok, Session.t()} | {:error, term()}
  def create_session(attrs \\ %{}, opts \\ []) do
    if Keyword.get(opts, :no_init, false) do
      change_session(%Session{}, attrs) |> Repo.insert()
    else
      case multi_create_session(attrs) |> Repo.transaction() do
        {:ok, %{session: session}} ->
          {:ok, session}

        {:error, :session, changeset, _changes_so_far} ->
          {:error, changeset}

        {:error, _failed_action, reason, _changes_so_far} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Creates a Session, raising an error on failure.
  """
  @spec create_session!(map) :: Session.t()
  def create_session!(attrs \\ %{}, opts \\ []) do
    create_session(attrs, opts)
    |> LogWatcher.maybe_raise_input_error("Errors creating session", :id)
  end

  @doc """
  Creates the session's log.
  """
  def init_session(%Session{log_dir: log_dir} = session) do
    case File.mkdir_p(log_dir) do
      :ok ->
        _ = Logger.info("accessed #{log_dir}")
        Session.write_event(session, :create_session)

      {:error, reason} ->
        _ = Logger.error("unable to create #{log_dir}")
        {:error, reason}
    end
  end

  @doc """
  Updates a session.

  ## Examples

      iex> update_session(session, %{field: new_value})
      {:ok, %Session{}}

      iex> update_session(session, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_session(Session.t(), map()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def update_session(session, params) do
    session
    |> Session.update_gen_changeset(params)
    |> Repo.update()
  end

  @doc """
  Deletes a session.

  ## Examples

      iex> delete_session(session)
      {:ok, %Session{}}

      iex> delete_session(session)
      {:error, %Ecto.Changeset{}}

  """
  def delete_session(%Session{} = session) do
    Repo.delete(session)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking session changes.

  ## Examples

      iex> change_session(session)
      %Ecto.Changeset{data: %Session{}}

  """
  def change_session(%Session{} = session, attrs \\ %{}) do
    Session.changeset(session, attrs)
  end

  # Private functions

  defp multi_create_session(attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:session, change_session(%Session{}, attrs))
    |> Ecto.Multi.run(:init, fn _repo, %{session: session} -> init_session(session) end)
  end

  # Events

  @doc """
  Returns the list of events for a given session.

  ## Examples

      iex> list_events_for_session(session)
      [%Event{}, ...]

  """
  def list_events_for_session(session) do
    session_events_query(session)
    |> Repo.all()
  end

  def session_events_query(%Session{id: session_id}) do
    from(event in Event,
      left_join: session in assoc(event, :session),
      where: session.id == ^session_id,
      preload: [session: session]
    )
  end

  @doc """
  Returns the list of events for a given user.

  ## Examples

      iex> list_events_for_user(user)
      [%Event{}, ...]

  """
  def list_events_for_user(user) do
    user_events_query(user)
    |> Repo.all()
  end

  def user_events_query(%User{id: user_id}) do
    from(event in Event,
      left_join: session in assoc(event, :session),
      where: session.user_id == ^user_id,
      preload: [session: session]
    )
  end

  @doc """
  Gets a single event.

  Raises `Ecto.NoResultsError` if the Event does not exist.

  ## Examples

      iex> get_event!(123)
      %Event{}

      iex> get_event!(456)
      ** (Ecto.NoResultsError)

  """
  def get_event!(id) do
    Repo.get!(Event, id)
  end

  @doc """
  Events fetched from the repo do not have assocations loaded, so
  this function will get load the parent Session struct into the
  Event and its parent User struct into the Session.
  """
  def load_event_user_and_session(event) do
    event = Repo.preload(event, :session)
    {:ok, %Event{event | session: Repo.preload(event.session, :user)}}
  end

  @doc """
  Creates a event.

  ## Examples

      iex> create_event(%{field: value})
      {:ok, %Event{}}

      iex> create_event(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_event(attrs) do
    change_event(%Event{}, attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a event from the parsed JSON line in a command
  log file.

  ## Examples

      iex> create_event_from_log_watcher(%{field: value})
      {:ok, %Event{}}

      iex> create_event_from_log_watcher(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_event_from_log_watcher(attrs) do
    change_event_from_log_watcher(%Event{}, attrs)
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking event changes.

  ## Examples

      iex> change_event(event)
      %Ecto.Changeset{data: %Event{}}

  """
  def change_event(event, attrs \\ %{}) do
    Event.changeset(event, attrs)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking event changes
  from the parsed JSON line in a command log file.

  ## Examples

      iex> change_event_from_log_watcher(event, attrs)
      %Ecto.Changeset{data: %Event{}}

  """
  def change_event_from_log_watcher(event, attrs) do
    Event.log_watcher_changeset(event, attrs)
  end
end
