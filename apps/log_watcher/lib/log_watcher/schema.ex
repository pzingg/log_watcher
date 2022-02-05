defmodule LogWatcher.Schema do
  @moduledoc false

  alias LogWatcher.Accounts.User
  alias LogWatcher.Sessions.Event
  alias LogWatcher.Sessions.Session

  @type user_assoc() :: Ecto.Association.NotLoaded.t() | User.t()
  @type session_assoc() :: Ecto.Association.NotLoaded.t() | Session.t()
  @type sessions_assoc() :: Ecto.Association.NotLoaded.t() | [Session.t()]
  @type events_assoc() :: Ecto.Association.NotLoaded.t() | [Event.t()]
end
