defmodule Translations.ErrorMessageTest do
  use ExUnit.Case

  defmodule TestSession do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :log_dir, :string, null: false
    end

    def changeset(%__MODULE__{} = session, params) do
      session
      |> Ecto.Changeset.cast(params, [:log_dir])
      |> Ecto.Changeset.validate_required([:log_dir])
      |> Ecto.Changeset.validate_length(:log_dir, max: 20)
    end
  end

  test "humanizes a field name that has underscores" do
    text = Translations.humanize_field(:private__session_id)
    assert text == "private session"
  end

  test "humanizes a field name using gettext" do
    text = Translations.humanize_field(:log_dir)
    assert text == "the log directory"
  end

  test "translates an error message using gettext" do
    params = %{
      "log_dir" => "/log/path/must/be/less/than/twenty/characters"
    }

    fields = [:log_dir]

    {:error, changeset} =
      %TestSession{}
      |> TestSession.changeset(params)
      |> Ecto.Changeset.apply_action(:insert)

    messages = Translations.changeset_error_messages(changeset)
    first_message = messages |> hd |> hd
    assert first_message == "The log directory should be at most 20 character(s)."
  end
end
