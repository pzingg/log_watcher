defmodule LogWatcher.Pipeline do
  @moduledoc """
  Recieves Messages events from Producer.
  """
  use Broadway

  require Logger

  alias Broadway.Message

  def start_link(opts) do
    {producer_opts, next_opts} = Keyword.split(opts, [:producer_opts])

    batchers =
      if Keyword.get(next_opts, :batching, false) do
        [default: [batch_size: 1, batch_timeout: 5000]]
      else
        []
      end

    config = [
      name: __MODULE__,
      producer: [
        module: {LogWatcher.Pipeline.Producer, producer_opts},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 5]
      ],
      batchers: batchers
    ]

    Broadway.start_link(__MODULE__, config)
  end

  # Callbacks

  @impl true
  def handle_message(_default_processor, %Message{data: data} = message, _context) do
    Logger.error("Pipeline handle #{inspect(data)}")

    next_message = Message.update_data(message, &LogWatcher.Pipeline.Handler.process_data/1)

    batchers = Broadway.topology(__MODULE__)[:batchers]

    if Keyword.has_key?(batchers, :default) do
      Message.put_batcher(next_message, :default)
    else
      next_message
    end
  end

  @impl true
  def handle_batch(_default_batcher, messages, _batch_info, _context) do
    list = Enum.map(messages, fn e -> e.data end)

    Logger.error("Pipeline batch #{inspect(list)}")

    messages
  end
end
