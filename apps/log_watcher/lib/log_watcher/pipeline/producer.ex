defmodule LogWatcher.Pipeline.Producer do
  @moduledoc """
  A GenStage producer that recieves events pushed from LogWatcher via
  the `:notify` call, and provides them to Broadway.
  """
  use GenStage

  require Logger

  # Callbacks

  @impl true
  @doc """
  State is not used.
  """
  def init(_arg) do
    {:producer, :ok}
  end

  @impl true
  @doc """
  Dispatch event immediately (using GenStage built-in buffering if necessary).
  """
  def handle_call({:notify, event}, _from, state) do
    {:reply, :ok, [event], state}
  end

  @impl true
  @doc """
  Never returns events, because we don't store them in state.
  """
  def handle_demand(_demand, state) do
    {:noreply, [], state}
  end
end
