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
          log_dir: String.t(),
          gen: integer() | nil,
          acked_event_id: integer() | nil,
          user_id: Ecto.ULID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, Ecto.ULID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]
  schema "sessions" do
    field(:name, :string)
    field(:description, :string)
    field(:tag, :string)
    field(:log_dir, :string)
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

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic) do
    _ = Logger.debug("#{inspect(self())} subscribing to #{topic}")
    Phoenix.PubSub.subscribe(LogWatcher.PubSub, topic)
  end

  @spec write_event(t(), atom(), Keyword.t()) :: {:ok, t()} | {:error, term()}
  def write_event(
        %__MODULE__{id: session_id, log_dir: log_dir} = session,
        event_type,
        opts \\ []
      ) do
    event = log_event(session, event_type, opts)

    with {:ok, content} <- Jason.encode(event) do
      file_name = log_file_name(session_id)
      log_file_path = Path.join(log_dir, file_name)
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
    |> Map.put(:session_id, map.id)
    |> Map.delete(:id)
  end

  @spec log_event(t(), atom(), Keyword.t()) :: map()
  def log_event(%__MODULE__{} = session, event_type, opts \\ []) do
    event =
      session
      |> to_map()
      |> Map.merge(%{time: LogWatcher.format_utcnow(), event: event_type})

    Enum.into(opts, event)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:name, :description, :tag, :log_dir, :gen, :acked_event_id])
    |> validate_required([:name, :description, :tag, :log_dir])
    |> unique_constraint(:tag)
  end

  @doc false
  def update_gen_changeset(session, attrs) do
    session
    |> cast(attrs, [:gen])
    |> validate_required([:gen])
  end
end
