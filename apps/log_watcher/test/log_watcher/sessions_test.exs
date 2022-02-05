defmodule LogWatcher.SessionsTest do
  use LogWatcher.DataCase, async: false

  alias LogWatcher.Sessions

  describe "sessions" do
    import LogWatcher.AccountsFixtures
    import LogWatcher.SessionsFixtures

    alias LogWatcher.Sessions.Session

    @update_attrs %{gen: 0}
    @invalid_attrs %{
      name: nil,
      description: nil,
      log_dir: nil,
      gen: nil
    }

    test "list_sessions/0 returns all sessions" do
      session = session_fixture()
      assert Sessions.list_sessions() == [session]
    end

    test "get_session!/1 returns the session with given id" do
      session = session_fixture()
      assert Sessions.get_session!(session.id) == session
    end

    test "create_session/1 with valid data creates a session" do
      user = user_fixture()

      create_attrs = %{
        user_id: user.id,
        name: "Test session",
        description: "A test session",
        log_dir: LogWatcher.session_log_dir(),
        gen: -1
      }

      assert {:ok, %Session{}} = Sessions.create_session(create_attrs)
    end

    test "create_session/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Sessions.create_session(@invalid_attrs)
    end

    test "update_session/2 with valid data updates the session" do
      session = session_fixture()
      assert {:ok, %Session{}} = Sessions.update_session(session, @update_attrs)
    end

    test "update_session/2 with invalid data returns error changeset" do
      session = session_fixture()
      assert {:error, %Ecto.Changeset{}} = Sessions.update_session(session, @invalid_attrs)
      assert session == Sessions.get_session!(session.id)
    end

    test "delete_session/1 deletes the session" do
      session = session_fixture()
      assert {:ok, %Session{}} = Sessions.delete_session(session)
      assert_raise Ecto.NoResultsError, fn -> Sessions.get_session!(session.id) end
    end

    test "change_session/1 returns a session changeset" do
      session = session_fixture()
      assert %Ecto.Changeset{} = Sessions.change_session(session)
    end
  end
end
