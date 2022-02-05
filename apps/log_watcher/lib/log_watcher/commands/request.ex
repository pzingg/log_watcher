defmodule LogWatcher.Commands.Request do
  @moduledoc """
  Defines a Request struct for use with schemaless changesets.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{
          command_id: String.t(),
          command_name: String.t(),
          script_file: String.t(),
          space_type: String.t(),
          num_lines: integer(),
          error: String.t()
        }

  @primary_key false
  embedded_schema do
    field :command_id, :string
    field :command_name, :string
    field :script_file, :string
    field :space_type, :string
    field :num_lines, :integer
    field :error, :string
  end

  def changeset(request, params \\ %{}) do
    request
    |> cast(params, [:command_id, :command_name, :script_file, :space_type, :num_lines, :error])
    |> validate_required([:command_id, :command_name, :script_file, :space_type, :num_lines])
  end

  def to_command_args(request) do
    script_path = Path.join(LogWatcher.script_dir(), request.script_file)

    %{
      script_path: script_path,
      error: request.error,
      num_lines: request.num_lines,
      space_type: request.space_type
    }
  end
end
