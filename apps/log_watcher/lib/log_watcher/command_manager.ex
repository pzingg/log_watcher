defmodule LogWatcher.CommandManager do
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
    GenServer.call(__MODULE__, {:start_script, session, command_id, command_name, command_args})
  end

  def await(key, timeout) when is_integer(timeout) do
    GenServer.call(__MODULE__, {:await, key, timeout}, timeout + 1000)
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
    await_start = Map.get(command_args, :await_start, true)
    job_id = Map.get(command_args, :oban_job_id, 0)

    case CommandSupervisor.start_script_runner(session, command_id, command_name, command_args) do
      {:ok, pid} ->
        state = [%__MODULE__{command_id: command_id, job_id: job_id} | state]
        send(self(), {:run_script, from, pid, await_start})
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

  @doc false
  @impl true
  def handle_info({:run_script, from, pid, await_start}, state) do
    reply = GenServer.call(pid, {:run_script, await_start})
    GenServer.reply(from, reply)
    {:noreply, state}
  end

  def handle_info({:task_started, command_id, task}, state) do
    Logger.info("CommandManager task_started for #{command_id}")

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
    Logger.error("CommandManager :DOWN #{inspect(ref)} #{inspect(pid)} #{reason}")
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.error("CommandManager :EXIT #{inspect(pid)} #{reason}")
    {:noreply, state}
  end

  def handle_info(unexpected, state) do
    Logger.error("CommandManager unexpected #{inspect(unexpected)}")
    {:noreply, state}
  end

  @doc false
  @impl true
  def terminate(reason, _state) do
    Logger.error("CommandManager terminate #{reason}")
    :ok
  end

  # Private functions

  defp get_command_id(nil, key, key_type, state) do
    Logger.error("CommandManager could not find #{key_type} #{inspect(key)} in #{inspect(state)}")
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
