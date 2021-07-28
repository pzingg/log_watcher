defmodule LogWatcher.Tasks.Session do
  @moduledoc """
  Defines a Session struct for use with schemaless changesets.
  Sessions are not stored in a SQL database.
  """

  use TypedStruct

  typedstruct do
    @typedoc "A daptics session on disk somewhere"

    plugin TypedStructEctoChangeset
    field :session_id, String.t(), enforce: true
    field :session_log_path, String.t(), enforce: true
    field :gen, integer(), default: -1
  end

  def new() do
    nil_values =
      @enforce_keys
      |> Enum.map(fn key -> {key, nil} end)
    Kernel.struct(__MODULE__, nil_values)
  end

  def required_fields(fields \\ [])
  def required_fields([]), do: @enforce_keys
  def required_fields(fields) when is_list(fields), do: @enforce_keys -- fields

  def changeset_fields(), do: Map.keys(__changeset__())

  def changeset_types(), do: @changeset_fields
end
