defmodule LogWatcher.Sessions.Event do
  @moduledoc """
  Structure and type for Event model.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias LogWatcher.Sessions.Session

  @typedoc """
  Definition of the Event struct.
  * :id - Identifier
  * :transaction_id - Transaction identifier, if event belongs to a transaction
  * :version - Version number
  * :topic - Topic name
  * :data - Context
  * :ttl - Time to live value
  * :source - Who created this event: module, function or service name are good
  * :initialized_at - When the process initialized to generate this event
  * :occurred_at - When it is occurred
  """
  @type t :: %__MODULE__{
          id: integer(),
          version: integer(),
          topic: String.t(),
          type: String.t(),
          source: String.t() | nil,
          data: any(),
          session_id: Ecto.ULID.t(),
          transaction_id: String.t(),
          ttl: integer() | nil,
          initialized_at: DateTime.t() | nil,
          occurred_at: DateTime.t() | nil
        }

  @primary_key {:id, :id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime, inserted_at: false, updated_at: :occurred_at]
  schema "events" do
    field(:version, :integer)
    field(:topic, :string)
    field(:type, :string)
    field(:source, :string)
    field(:data, :map)
    field(:session_id, Ecto.ULID)
    field(:transaction_id, :string)
    field(:ttl, :integer)
    field(:initialized_at, :utc_datetime)

    timestamps()
  end

  @doc """
  Calculates the duration of the event, and simple answer of how long does it
  take to generate this event.
  """
  @spec duration(__MODULE__.t()) :: integer()
  def duration(%__MODULE__{
        initialized_at: initialized_at,
        occurred_at: occurred_at
      })
      when not (is_nil(initialized_at) or is_nil(occurred_at)) do
    DateTime.diff(occurred_at, initialized_at, :millisecond)
  end

  def duration(%__MODULE__{}) do
    0
  end

  @spec session_topic(String.t() | t()) :: String.t()
  def session_topic(session_id) when is_binary(session_id) do
    "session:#{session_id}"
  end

  def session_topic(%Session{id: session_id}) do
    "session:#{session_id}"
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :version,
      :topic,
      :type,
      :source,
      :data,
      :session_id,
      :transaction_id,
      :ttl,
      :initialized_at
    ])
    |> validate_required([:topic, :data])
  end

  # %{
  #  errors: [],
  #  event_type: :task_updated,
  #  file_name: "01FT9CJDKYK7M95QQ198B8VGGZ-0003-update-T4021-log.jsonl",
  #  gen: 3,
  #  level: 6,
  #  log_dir: ".../sessions/01FT9CJDJ5KQ95CN1MYMACYD6Y/output",
  #  message: "Command T4021 started on line 1",
  #  os_pid: 131882,
  #  progress: nil,
  #  session_id: "01FT9CJDKYK7M95QQ198B8VGGZ",
  #  started_at: "2022-01-25T11:49:28",
  #  status: "started",
  #  command_id: "T4021",
  #  name: "update",
  #  time: "2022-01-25T11:49:28"
  # }
  def log_watcher_changeset(event, %{event_type: event_type} = attrs) do
    event_type = stringize(event_type)

    {attrs, data} =
      attrs
      |> Map.drop([:task_ref, :event_type])
      |> Map.split([:session_id, :name, :command_id, :time])

    session_id = Map.fetch!(attrs, :session_id)
    topic = session_topic(session_id)
    command_id = Map.get(attrs, :command_id)
    name = Map.get(attrs, :name)

    attrs =
      attrs
      |> Map.merge(%{
        version: 1,
        type: event_type,
        topic: topic,
        source: name,
        session_id: session_id,
        transaction_id: command_id,
        data: data,
        initialized_at: Map.get_lazy(attrs, :time, fn -> DateTime.utc_now() end)
      })

    changeset(event, attrs)
  end

  defp stringize(nil), do: ""
  defp stringize(v) when is_atom(v), do: Atom.to_string(v)
  defp stringize(v) when is_binary(v), do: v
  defp stringize(_), do: raise("Invalid type for stringize")
end
