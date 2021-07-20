defmodule LogWatcher.Tasks.Session do
  @moduledoc """
  Defines a Session struct for use with schemaless changesets.
  Sessions are not stored in a SQL database.
  """

  defstruct [:session_id, :session_log_path]

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          session_log_path: String.t() | nil
        }
end
