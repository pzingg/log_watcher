defmodule LogWatcher.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  alias LogWatcher.Sessions.Session

  @primary_key {:id, Ecto.ULID, autogenerate: true}
  schema "users" do
    field :first_name, :string
    field :last_name, :string

    has_many :sessions, Session
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:first_name, :last_name])
    |> validate_required([:first_name, :last_name])
  end
end
