defmodule LogWatcher.Pipeline do
  @moduledoc """
  Configures a Broadway pipeline that recieves events from the
  `Pipeline.Producer` module. The `Pipeline.Handler` module
  processes these events, inserting them into an Ecto repository.
  """
  use Broadway

  require Logger

  alias Broadway.Message

  def start_link(opts) do
    {producer_opts, opts} = Keyword.pop(opts, :producer_opts, [])

    batchers =
      if Keyword.get(opts, :batching, false) do
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
    messages
  end
end
