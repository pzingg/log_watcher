defmodule LogWatcher.Tasks.Session do
  @moduledoc """
  Defines a schema for sessions, not stored in a SQL database.
  """

  use Ecto.Schema

  @primary_key {:session_id, :string, []}
  embedded_schema do
    field :session_log_path, :string
  end

  @type t :: %__MODULE__{
    session_id: String.t() | nil,
    session_log_path: String.t() | nil,
  }

  @create_fields [
    :session_id,
    :session_log_path,
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, params \\ %{}) do
    session
    |> Ecto.Changeset.cast(params, @create_fields)
    |> Ecto.Changeset.validate_required(@create_fields)
  end
end
