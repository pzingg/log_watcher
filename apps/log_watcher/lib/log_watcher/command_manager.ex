defmodule LogWatcher.CommandManager do
  @moduledoc """
  Maintains a map of started commands, associating
  the `command_id`, Oban `job_id`, and the `ref` and `pid`
  of the Elixir Task that is running the command, so that
  clients can send requests to the associated ScriptRunner
  process using any of the four keys.
  """
  use GenServer

  require Logger

  alias LogWatcher.CommandSupervisor
  alias LogWatcher.ScriptRunner

  @enforce_keys [:command_id, :job_id]

  defstruct command_id: nil,
            job_id: 0,
            task_ref: nil,
            task_pid: nil

  @type t() :: %__MODULE__{
          command_id: String.t(),
          job_id: integer(),
          task_ref: reference() | nil,
          task_pid: pid() | nil
        }

  @type state() :: [t()]
  @type key() :: String.t() | integer() | reference() | pid()

  # Public interface

  def start_link(arg) do
    GenServer.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def start_script(session, command_id, command_name, command_args) do
    timeout = Map.get(command_args, :timeout, 5000)

    GenServer.call(
      __MODULE__,
      {:start_script, session, command_id, command_name, command_args},
      timeout + 100
    )
  end

  def await(key, timeout) when is_integer(timeout) do
    GenServer.call(__MODULE__, {:await, key, timeout}, timeout + 100)
  end

  def cancel(key) do
    GenServer.call(__MODULE__, {:cancel, key})
  end

  def kill(key) do
    GenServer.call(__MODULE__, {:kill, key})
  end

  # Callbacks

  @doc false
  @impl true
  def init(_arg) do
    # Trap exits so we terminate if ScriptRunner dies
    _ = Process.flag(:trap_exit, true)

    {:ok, []}
  end

  @doc false
  @impl true
  def handle_call({:start_script, session, command_id, command_name, command_args}, from, state) do
    timeout = Map.get(command_args, :timeout, 5000)
    await_running = Map.get(command_args, :await_running, true)
    job_id = Map.get(command_args, :oban_job_id, 0)

    case CommandSupervisor.start_script_runner(session, command_id, command_name, command_args) do
      {:ok, _pid} ->
        state = [%__MODULE__{command_id: command_id, job_id: job_id} | state]
        send(self(), {:run_script, from, command_id, await_running, timeout})
        {:noreply, state}

      :ignore ->
        {:reply, :ignore, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:await, key, timeout}, _from, state) do
    case find_runner(state, key) do
      nil -> {:reply, {:error, :not_found}, state}
      command_id -> {:reply, ScriptRunner.await_exit(command_id, timeout), state}
    end
  end

  def handle_call({:cancel, key}, _from, state) do
    case find_runner(state, key) do
      nil -> {:reply, {:error, :not_found}, state}
      command_id -> {:reply, ScriptRunner.cancel(command_id), state}
    end
  end

  def handle_call({:kill, key}, _from, state) do
    case find_runner(state, key) do
      nil -> {:reply, {:error, :not_found}, state}
      command_id -> {:reply, ScriptRunner.kill(command_id), state}
    end
  end

  @doc """
  The `:run_script` message does a sync call to the ScriptRunner process for
  this command, which may not return immediately (depending on the
  `:await_running` setting).
  """
  @impl true
  def handle_info({:run_script, from, command_id, await_running, timeout}, state) do
    reply = ScriptRunner.run_script(command_id, await_running, timeout)
    GenServer.reply(from, reply)
    {:noreply, state}
  end

  def handle_info({:task_started, command_id, task}, state) do
    _ = Logger.debug("CommandManager task_started for #{command_id}")

    state =
      Enum.map(state, fn %__MODULE__{command_id: value} = command ->
        if value == command_id do
          %__MODULE__{command | task_ref: task.ref, task_pid: task.pid}
        else
          command
        end
      end)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, pid, reason}, state) do
    _ = Logger.debug("CommandManager :DOWN #{inspect(ref)} #{inspect(pid)} #{reason}")
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    _ = Logger.debug("CommandManager :EXIT #{inspect(pid)} #{reason}")
    {:noreply, state}
  end

  def handle_info(unexpected, state) do
    _ = Logger.debug("CommandManager unexpected #{inspect(unexpected)}")
    {:noreply, state}
  end

  @doc false
  @impl true
  def terminate(reason, _state) do
    _ = Logger.debug("CommandManager terminate #{reason}")
    :ok
  end

  # Private functions

  defp get_command_id(nil, key, key_type, state) do
    _ =
      Logger.debug(
        "CommandManager could not find #{key_type} #{inspect(key)} in #{inspect(state)}"
      )

    nil
  end

  defp get_command_id(%__MODULE__{command_id: command_id}, _key, _key_type, _state) do
    command_id
  end

  defp find_runner(_state, 0), do: nil
  defp find_runner(_state, nil), do: nil

  defp find_runner(state, command_id) when is_binary(command_id) do
    Enum.find(state, fn %__MODULE__{command_id: value} -> value == command_id end)
    |> get_command_id(command_id, :command_id, state)
  end

  defp find_runner(state, job_id) when is_integer(job_id) do
    Enum.find(state, fn %__MODULE__{job_id: value} -> value == job_id end)
    |> get_command_id(job_id, :job_id, state)
  end

  defp find_runner(state, task_pid) when is_pid(task_pid) do
    Enum.find(state, fn %__MODULE__{task_pid: value} -> value == task_pid end)
    |> get_command_id(task_pid, :task_pid, state)
  end

  defp find_runner(state, task_ref) when is_reference(task_ref) do
    Enum.find(state, fn %__MODULE__{task_ref: value} -> value == task_ref end)
    |> get_command_id(task_ref, :task_ref, state)
  end
end
