defmodule LogWatcher.SessionsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `LogWatcher.Sessions` context.
  """

  alias LogWatcher.Accounts
  alias LogWatcher.AccountsFixtures
  alias LogWatcher.Sessions

  @doc """
  Generate a session.
  """
  def session_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Test session",
        description: "A test session",
        log_dir: LogWatcher.session_log_dir(),
        gen: -1
      })

    :ok = File.mkdir_p(LogWatcher.session_base_dir())
    user = AccountsFixtures.user_fixture()
    {:ok, session} = Sessions.create_session(Map.put(attrs, :user_id, user.id))

    session
  end

  def session_and_user_fixture(attrs \\ %{}) do
    session = session_fixture(attrs)
    user = Accounts.get_user!(session.user_id)
    %{session: session, user: user}
  end
end
