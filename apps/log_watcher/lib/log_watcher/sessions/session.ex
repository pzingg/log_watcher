defmodule LogWatcher.Sessions.Session do
  @moduledoc """
  A session represents a directory on the file system that will
  contain the executable scripts, data and log files necessary to
  perform long running tasks.  Each session has a required
  `:name` and `:description`, and a unique ID, the `:session_id`
  (usually a UUID or ULID).
  """
  use Ecto.Schema
  import Ecto.Changeset

  require Logger

  alias LogWatcher.Accounts.User
  alias LogWatcher.Sessions.Event

  @type t() :: %__MODULE__{
          id: Ecto.ULID.t(),
          name: String.t(),
          description: String.t(),
          tag: String.t(),
          log_path: String.t(),
          gen: integer() | nil,
          acked_event_id: integer() | nil,
          user_id: Ecto.ULID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, Ecto.ULID, autogenerate: true}
  schema "sessions" do
    field(:name, :string)
    field(:description, :string)
    field(:tag, :string)
    field(:log_path, :string)
    field(:gen, :integer)
    field(:acked_event_id, :integer)
    belongs_to(:user, User)
    has_many(:events, Event)

    timestamps()
  end

  @spec log_file_name(String.t() | t()) :: String.t()
  def log_file_name(session_id) when is_binary(session_id) do
    "#{session_id}-sesslog.jsonl"
  end

  def log_file_name(%__MODULE__{id: session_id}) do
    "#{session_id}-sesslog.jsonl"
  end

  ## PubSub utilities
  @spec events_topic(String.t() | t()) :: String.t()
  def events_topic(session_id) when is_binary(session_id) do
    "session:#{session_id}"
  end

  def events_topic(%__MODULE__{id: session_id}) do
    "session:#{session_id}"
  end

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic) do
    _ = Logger.info("#{inspect(self())} subscribing to #{topic}")
    Phoenix.PubSub.subscribe(LogWatcher.PubSub, topic)
  end

  @spec broadcast(String.t(), term()) :: :ok | {:error, term()}
  def broadcast(topic, message) when is_tuple(message) do
    _ = Logger.info("#{inspect(self())} broadcasting :#{Kernel.elem(message, 0)} to #{topic}")
    Phoenix.PubSub.broadcast(LogWatcher.PubSub, topic, message)
  end

  @spec write_event(t(), atom(), Keyword.t()) :: {:ok, t()} | {:error, term()}
  def write_event(
        %__MODULE__{id: session_id, log_path: session_log_path} = session,
        event_type,
        opts \\ []
      ) do
    event = create_event(session, event_type, opts)

    with {:ok, content} <- Jason.encode(event) do
      file_name = log_file_name(session_id)
      log_file_path = Path.join(session_log_path, file_name)
      File.write(log_file_path, content <> "\n")
      {:ok, session}
    end
  end

  def to_map(session) do
    map =
      Map.from_struct(session)
      |> Map.drop([
        :__meta__,
        :user,
        :events,
        :user_id,
        :acked_event_id,
        :inserted_at,
        :updated_at
      ])

    map
    |> Map.merge(%{session_id: map.id, session_log_path: map.log_path})
    |> Map.drop([:id, :log_path])
  end

  @spec create_event(t(), atom(), Keyword.t()) :: map()
  def create_event(%__MODULE__{} = session, event_type, opts \\ []) do
    event =
      session
      |> to_map()
      |> Map.merge(%{time: LogWatcher.format_utcnow(), event: event_type})

    Enum.into(opts, event)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:name, :description, :tag, :log_path, :gen, :acked_event_id])
    |> validate_required([:name, :description, :tag, :log_path])
    |> unique_constraint(:tag)
  end

  @doc false
  def update_gen_changeset(session, attrs) do
    session
    |> cast(attrs, [:gen])
    |> validate_required([:gen])
  end
end
