defmodule LogWatcher.Pipeline.Handler do
  @moduledoc """
  A Utility module for the Broadway pipeline.
  It handles transforming LogWatcher events into Broadway.Messages,
  inserting them into the database, and publishing them on
  Phoenix PubSub after they have been inserted.
  """

  require Logger

  alias LogWatcher.Accounts.User
  alias LogWatcher.Sessions
  alias LogWatcher.Sessions.Session

  @doc """
  Sends an event to the producer and returns only after the event is dispatched.
  Transforms incoming event to a Broadway message.
  """
  def sync_notify(event, timeout \\ 5000) do
    case Broadway.producer_names(LogWatcher.Pipeline) do
      [producer] ->
        broadway_message = transform_event(event)
        GenStage.call(producer, {:notify, broadway_message}, timeout)

      [] ->
        _ = Logger.debug("sync_notify: no producer to notify")
        {:error, :no_producer}

      _ ->
        _ = Logger.debug("sync_notify: too many producers")
        {:error, :more_than_one_producer}
    end
  end

  @doc """
  A transformer function that Wraps LogWatcher events into Broadway.Messages,
  """
  def transform_event(event, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    %Broadway.Message{
      data: event,
      metadata: metadata,
      acknowledger: {Broadway.NoopAcknowledger, nil, nil}
    }
  end

  @doc """
  Process the data in an incoming message by inserting the event into
  the database. If the insert is successful, the event is broadcast
  over its topics.
  """
  def process_data(data) do
    with {:ok, event} <- LogWatcher.Sessions.create_event_from_log_watcher(data),
         {:ok, event} <- Sessions.load_event_user_and_session(event) do
      _ =
        Phoenix.PubSub.broadcast(
          LogWatcher.PubSub,
          Session.session_topic(event.session),
          {:event, event}
        )

      _ =
        Phoenix.PubSub.broadcast(
          LogWatcher.PubSub,
          User.user_topic(event.session.user),
          {:event, event}
        )
    else
      {:error, changeset} ->
        _ = Logger.debug("Failed to insert event #{inspect(changeset.errors)}")
    end

    data
  end
end
