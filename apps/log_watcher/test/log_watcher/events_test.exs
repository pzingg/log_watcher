defmodule LogWatcher.EventsTest do
  use LogWatcher.DataCase, async: false

  alias LogWatcher.Sessions

  describe "events" do
    alias LogWatcher.Sessions.Event

    import LogWatcher.EventsFixtures
    import LogWatcher.SessionsFixtures

    @invalid_attrs %{
      session_id: nil,
      version: nil,
      type: nil,
      source: nil,
      data: nil,
      command_id: nil,
      initialized_at: nil
    }

    test "list_events_for_session/0 returns all events" do
      %{event: event, session: session} = event_and_session_fixture()
      assert Sessions.list_events_for_session(session) == [%{event | session: session}]
    end

    test "get_event!/1 returns the event with given id" do
      event = event_fixture()
      assert Sessions.get_event!(event.id) == event
    end

    test "create_event/1 with valid data creates a event" do
      ts = LogWatcher.now()
      session = session_fixture()
      command_id = Ecto.ULID.generate()

      valid_attrs = %{
        session_id: session.id,
        version: 1,
        type: "command_updated",
        source: "create",
        data: %{
          "message" => "started",
          "status" => "running",
          "time" => ts
        },
        command_id: command_id,
        initialized_at: ts
      }

      assert {:ok, %Event{}} = Sessions.create_event(valid_attrs)
    end

    test "create_event/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Sessions.create_event(@invalid_attrs)
    end

    test "change_event/1 returns a event changeset" do
      event = event_fixture()
      assert %Ecto.Changeset{} = Sessions.change_event(event)
    end
  end
end
