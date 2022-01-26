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
  def init(opts) do
    _ = Logger.error("Producer init #{inspect(opts)}")
    {:producer, %{draining: false, test_pid: Keyword.get(opts, :test_pid)}}
  end

  @impl true
  @doc """
  Dispatch event immediately (using GenStage built-in buffering if necessary).
  """
  def handle_call({:notify, event}, _from, state) do
    if state.draining do
      {:reply, :ok, [], state}
    else
      {:reply, :ok, [event], state}
    end
  end

  @impl true
  @doc """
  Never returns events, because we don't store them in state.
  """
  def handle_demand(_demand, state) do
    {:noreply, [], state}
  end

  @doc false
  def prepare_for_draining(%{test_pid: test_pid} = state) do
    if !is_nil(test_pid) && Process.alive?(test_pid) do
      _ = send(test_pid, :broadway_exit)
    end

    {:noreply, [], %{state | draining: true, test_pid: nil}}
  end
end
