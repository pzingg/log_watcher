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
          source: String.t() | nil,
          data: any(),
          session_id: Ecto.ULID.t(),
          transaction_id: String.t(),
          ttl: integer() | nil,
          initialized_at: integer() | nil,
          occurred_at: integer() | nil
        }

  @primary_key {:id, :id, autogenerate: true}
  schema "events" do
    field(:version, :integer)
    field(:topic, :string)
    field(:source, :string)
    field(:data, :map)
    field(:transaction_id, :string)
    field(:ttl, :integer)
    field(:initialized_at, :integer)
    field(:occurred_at, :integer)

    belongs_to :session, Session
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
      when is_integer(initialized_at) and is_integer(occurred_at) do
    occurred_at - initialized_at
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
      :source,
      :data,
      :user_id,
      :session_id,
      :transaction_id,
      :ttl,
      :initialized_at,
      :occurred_at
    ])
    |> validate_required([:topic, :data])
  end
end
