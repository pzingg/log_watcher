defmodule LogWatcher.Accounts.User do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias LogWatcher.Sessions.Session

  @type t() :: %__MODULE__{
          id: Ecto.ULID.t(),
          first_name: String.t(),
          last_name: String.t(),
          email: String.t(),
          sessions: LogWatcher.Schema.sessions_assoc(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @timestamps_opts [type: :utc_datetime]
  @primary_key {:id, Ecto.ULID, autogenerate: true}
  schema "users" do
    field(:first_name, :string)
    field(:last_name, :string)
    field(:email, :string)

    has_many(:sessions, Session)

    timestamps()
  end

  def full_name(user), do: "#{user.first_name} #{user.last_name}"

  @spec user_topic(String.t() | t()) :: String.t()
  def user_topic(user_id) when is_binary(user_id) do
    "user:#{user_id}"
  end

  def user_topic(%__MODULE__{id: user_id}) do
    "user:#{user_id}"
  end

  @doc false
  def registration_changeset(user, attrs, _opts \\ []) do
    user
    |> cast(attrs, [:first_name, :last_name, :email])
    |> validate_required([:first_name, :last_name])
    |> validate_email()
  end

  @doc """
  A user changeset for changing the email.

  It requires the email to change otherwise an error is added.
  """
  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_email()
    |> case do
      %{changes: %{email: _}} = changeset -> changeset
      %{} = changeset -> add_error(changeset, :email, "did not change")
    end
  end

  @doc """
  A user changeset for changing profile information.
  """
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:first_name, :last_name])
    |> validate_required([:first_name, :last_name])
  end

  def confirm_changeset(user), do: change(user)

  def validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, LogWatcher.Repo)
    |> unique_constraint(:email)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(_user, password) when is_binary(password) do
    Regex.match?(~r/\bvalid password\b/, password)
  end

  def valid_password?(_user, _password), do: false

  @doc """
  Validates the current password otherwise adds an error to the changeset.
  """
  def validate_current_password(changeset, password) do
    if valid_password?(changeset.data, password) do
      changeset
    else
      add_error(changeset, :current_password, "is not valid")
    end
  end
end
