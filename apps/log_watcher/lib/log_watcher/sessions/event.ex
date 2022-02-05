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
  * :command_id - Transaction identifier, if event belongs to a transaction
  * :version - Version number
  * :data - Context
  * :ttl - Time to live value
  * :source - Who created this event: module, function or service name are good
  * :initialized_at - When the process initialized to generate this event
  * :occurred_at - When it is occurred
  """
  @type t :: %__MODULE__{
          id: integer(),
          version: integer(),
          type: String.t(),
          source: String.t() | nil,
          data: any(),
          session: LogWatcher.Schema.session_assoc(),
          session_id: Ecto.ULID.t(),
          command_id: String.t(),
          ttl: integer() | nil,
          initialized_at: DateTime.t(),
          occurred_at: DateTime.t()
        }

  @primary_key {:id, :id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime, inserted_at: :occurred_at, updated_at: false]
  schema "events" do
    field(:version, :integer)
    field(:type, :string)
    field(:source, :string)
    field(:data, :map)
    field(:command_id, :string)
    field(:ttl, :integer)
    field(:initialized_at, :utc_datetime)

    belongs_to(:session, Session, type: Ecto.ULID, on_replace: :update)

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
      :session_id,
      :command_id,
      :version,
      :type,
      :source,
      :data,
      :ttl,
      :initialized_at
    ])
    |> validate_required([
      :session_id,
      :command_id,
      :version,
      :type,
      :source,
      :data,
      :initialized_at
    ])
    |> assoc_constraint(:session)
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
  #  command_name: "update",
  #  time: "2022-01-25T11:49:28"
  # }
  def log_watcher_changeset(event, %{event_type: event_type} = attrs) do
    event_type = stringize(event_type)

    {attrs, data} =
      attrs
      |> Map.drop([:task_ref, :event_type])
      |> Map.split([:session_id, :command_name, :command_id, :time])

    session_id = Map.fetch!(attrs, :session_id)
    command_id = Map.get(attrs, :command_id)
    command_name = Map.get(attrs, :command_name, "undefined")

    attrs =
      attrs
      |> Map.merge(%{
        version: 1,
        type: event_type,
        source: command_name,
        session_id: session_id,
        command_id: command_id,
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
