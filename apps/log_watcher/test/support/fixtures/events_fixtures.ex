defmodule LogWatcher.EventsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `LogWatcher.Sessions` context.
  """

  import LogWatcher.SessionsFixtures

  alias LogWatcher.Sessions

  @doc """
  Generate an event.
  """
  def event_and_session_fixture(attrs \\ %{}) do
    ts = LogWatcher.now()
    session = session_fixture()
    command_id = Ecto.ULID.generate()

    {:ok, event} =
      attrs
      |> Enum.into(%{
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
      })
      |> Sessions.create_event()

    %{event: event, session: session}
  end

  def event_fixture(attrs \\ %{}) do
    %{event: event} = event_and_session_fixture(attrs)
    event
  end
end
