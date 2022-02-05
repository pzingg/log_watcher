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

  @tag_length 16
  @max_tag_length 100

  @type t() :: %__MODULE__{
          id: Ecto.ULID.t(),
          name: String.t(),
          description: String.t(),
          tag: String.t(),
          log_dir: String.t(),
          gen: integer() | nil,
          acked_event_id: integer() | nil,
          user: LogWatcher.Schema.user_assoc(),
          user_id: Ecto.ULID.t(),
          events: LogWatcher.Schema.events_assoc(),
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

    belongs_to(:user, User, type: Ecto.ULID, on_replace: :update)
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

  @spec session_topic(String.t() | t()) :: String.t()
  def session_topic(session_id) when is_binary(session_id) do
    "session:#{session_id}"
  end

  def session_topic(%__MODULE__{id: session_id}) do
    "session:#{session_id}"
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
    file_name = log_file_name(session_id)
    log_file_path = Path.join(log_dir, file_name)
    event = log_event(session, event_type, opts)

    with {:ok, content} <- Jason.encode(event),
         :ok <- File.write(log_file_path, content <> "\n") do
      {:ok, session}
    else
      {:error, reason} ->
        _ = Logger.error("#{reason}: could not write to #{log_file_path}")
        {:error, reason}
    end
  end

  def to_map(session) do
    map =
      Map.from_struct(session)
      |> Map.drop([
        :__meta__,
        :user,
        :events,
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
      |> Map.merge(%{time: LogWatcher.now(), event: event_type})

    Enum.into(opts, event)
  end

  def generate_tag() do
    :crypto.strong_rand_bytes(@tag_length)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, @tag_length)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:user_id, :name, :description, :tag, :log_dir, :gen, :acked_event_id])
    |> validate_required([:user_id, :name, :description])
    |> assoc_constraint(:user)
    |> validate_tag()
    |> validate_log_dir()
  end

  @doc false
  def update_gen_changeset(session, attrs) do
    session
    |> cast(attrs, [:gen])
    |> validate_required([:gen])
  end

  defp validate_tag(changeset) do
    changeset =
      case get_change(changeset, :tag) do
        tag when is_binary(tag) -> changeset
        nil -> put_change(changeset, :tag, generate_tag())
      end

    changeset
    |> validate_required(:tag)
    |> validate_length(:tag, min: @tag_length, max: @max_tag_length)
    |> unique_constraint(:tag)
  end

  defp validate_log_dir(changeset) do
    changeset
    |> update_change(:log_dir, &set_log_dir(changeset, &1))
    |> validate_required(:log_dir)
  end

  defp set_log_dir(changeset, log_dir) do
    Regex.replace(~r/(^[^:]*)(:tag)(.*)$/, log_dir, fn _, prefix, _tag, suffix ->
      tag = get_change(changeset, :tag)
      "#{prefix}#{tag}#{suffix}"
    end)
  end
end
