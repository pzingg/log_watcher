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
  #  data: %{
  #    exit_status: 0,
  #    gen: 9,
  #    message: "read arg file",
  #    session_id: "01FT49N8EHPPDR2BPD0R74R4AP",
  #    log_dir: ".../sessions/01FT49N8CPDVQ9XV2P4G2GRWT7/output",
  #    status: "completed",
  #    task_id: "T3842",
  #    task_type: "create",
  #    time: "2022-01-23T12:22:23"
  #  },
  #  event_type: :script_terminated,
  #  topic: "session:01FT49N8EHPPDR2BPD0R74R4AP"
  # }

  def log_watcher_changeset(event, %{data: raw_data} = raw_attrs) do
    {event_type, attrs} = Map.pop!(raw_attrs, :event_type)
    {event_attrs, data} = Map.split(raw_data, [:session_id, :task_type, :task_id, :time])

    attrs =
      Map.merge(attrs, %{
        version: 1,
        type: stringize(event_type),
        data: data,
        source: Map.get(event_attrs, :task_type),
        session_id: Map.get(event_attrs, :session_id),
        transaction_id: Map.get(event_attrs, :task_id),
        initialized_at: Map.get_lazy(event_attrs, :time, fn -> DateTime.utc_now() end)
      })

    changeset(event, attrs)
  end

  defp stringize(nil), do: ""
  defp stringize(v) when is_atom(v), do: Atom.to_string(v)
  defp stringize(v) when is_binary(v), do: v
  defp stringize(_), do: raise("Invalid type for stringize")
end
