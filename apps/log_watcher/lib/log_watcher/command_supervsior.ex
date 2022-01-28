defmodule LogWatcher.CommandSupervisor do
  @moduledoc """
  Supervises dynamically started ScriptRunner child processes.
  The ScriptRunner GenServer processes can be accessed via `command_id`.
  """
  use DynamicSupervisor

  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start_script_runner(session, command_id, command_name, command_args) do
    child_spec =
      {LogWatcher.ScriptRunner,
       %{
         session: session,
         command_id: command_id,
         command_name: command_name,
         command_args: command_args
       }}

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @impl true
  def init(_arg) do
    # :one_for_one strategy: if a child process crashes, only that process is restarted.
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
