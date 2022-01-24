defmodule LogWatcher.Pipeline.Handler do
  @moduledoc """
  Wraps LogWatcher events into Broadway.Messages, and inserts events into the database.
  """

  require Logger

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
        Logger.error("sync_notify: no producer to notify")
        {:error, :no_producer}

      _ ->
        Logger.error("sync_notify: too many producers")
        {:error, :more_than_one_producer}
    end
  end

  @doc """
  A transformer function that Wraps LogWatcher events into Broadway.Messages,
  """
  def transform_event(event, opts \\ []) do
    %Broadway.Message{
      data: event,
      metadata: Keyword.get(opts, :metadata, %{}),
      acknowledger: {Broadway.NoopAcknowledger, nil, nil}
    }
  end

  @doc """
  Process the data in an incoming message by inserting the event into
  the database. If the insert is successful, the event is broadcast
  over its topic.
  """
  def process_data(data) do
    case LogWatcher.Sessions.create_event_from_log_watcher(data) do
      {:ok, event} ->
        _ = Phoenix.PubSub.broadcast(LogWatcher.PubSub, event.topic, event)

      {:error, changeset} ->
        _ = Logger.error("Failed to insert event #{inspect(changeset.errors)}")
    end

    data
  end
end
