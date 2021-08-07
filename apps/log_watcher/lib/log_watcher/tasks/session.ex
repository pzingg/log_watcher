defmodule LogWatcher.Tasks.Session do
  @moduledoc """
  Defines a Session struct for use with schemaless changesets.
  Sessions are not stored in a SQL database.

  A session represents a directory on the file system that will
  contain the executable scripts, data and log files necessary to
  perform long running tasks.  Each session has a required
  `:name` and `:description`, and a unique ID, the `:session_id`
  (usually a UUID or ULID).
  """

  use TypedStruct

  require Logger

  typedstruct do
    @typedoc "A daptics session on disk somewhere"

    plugin(TypedStructEctoChangeset)
    field(:session_id, String.t(), enforce: true)
    field(:name, String.t(), enforce: true)
    field(:description, String.t(), enforce: true)
    field(:session_log_path, String.t(), enforce: true)
    field(:gen, integer(), default: -1)
  end

  @spec new() :: t()
  def new() do
    nil_values =
      @enforce_keys
      |> Enum.map(fn key -> {key, nil} end)

    Kernel.struct(__MODULE__, nil_values)
  end

  @spec required_fields([atom()]) :: [atom()]
  def required_fields(fields \\ [])
  def required_fields([]), do: @enforce_keys

  def required_fields(fields) when is_list(fields) do
    @enforce_keys -- @enforce_keys -- fields
  end

  @spec all_fields() :: [atom()]
  def all_fields(), do: Keyword.keys(@changeset_fields)

  @spec changeset_types() :: [{atom(), atom()}]
  def changeset_types(), do: @changeset_fields

  @spec log_file_name(String.t() | t()) :: String.t()
  def log_file_name(session_id) when is_binary(session_id) do
    "#{session_id}-sesslog.jsonl"
  end

  def log_file_name(%__MODULE__{session_id: session_id}) do
    "#{session_id}-sesslog.jsonl"
  end

  ## PubSub utilities
  @spec events_topic(String.t() | t()) :: String.t()
  def events_topic(session_id) when is_binary(session_id) do
    "session:#{session_id}"
  end

  def events_topic(%__MODULE__{session_id: session_id}) do
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
        %__MODULE__{session_id: session_id, session_log_path: session_log_path} = session,
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

  @spec create_event(t(), atom(), Keyword.t()) :: map()
  def create_event(%__MODULE__{} = session, event_type, opts \\ []) do
    event =
      Map.from_struct(session)
      |> Map.merge(%{time: LogWatcher.format_utcnow(), event: event_type})

    Enum.into(opts, event)
  end
end
