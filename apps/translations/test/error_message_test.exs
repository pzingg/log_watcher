defmodule Translations.ErrorMessageTest do
  use ExUnit.Case

  defmodule TestSession do
    use TypedStruct

    typedstruct do
      @typedoc "A test structure"

      plugin(TypedStructEctoChangeset)
      field(:session_log_path, String.t(), enforce: true)
    end

    @spec new() :: t()
    def new() do
      nil_values =
        @enforce_keys
        |> Enum.map(fn key -> {key, nil} end)

      Kernel.struct(__MODULE__, nil_values)
    end

    def required_fields(fields \\ [])
    def required_fields([]), do: @enforce_keys

    def required_fields(fields) when is_list(fields) do
      @enforce_keys -- @enforce_keys -- fields
    end
  end

  test "humanizes a field name using gettext" do
    text = Translations.humanize_field(:session_log_path)
    assert text == "The log path"
  end

  test "translates an error message using gettext" do
    params = %{
      "session_log_path" => "/log/path/must/be/less/than/twenty/characters"
    }

    fields = [:session_log_path]

    {:error, changeset} =
      TestSession.new()
      |> Ecto.Changeset.cast(params, fields)
      |> Ecto.Changeset.validate_required(TestSession.required_fields(fields))
      |> Ecto.Changeset.validate_length(:session_log_path, max: 20)
      |> Ecto.Changeset.apply_action(:insert)

    messages = Translations.changeset_error_messages(changeset)
    first_message = messages |> hd |> hd
    assert first_message == "The log path should be at most 20 character(s)."
  end
end
