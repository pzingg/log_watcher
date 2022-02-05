defmodule LogWatcher.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use LogWatcher.DataCase, async: false`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  require Logger

  alias LogWatcher.CommandManager

  using do
    quote do
      alias LogWatcher.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import LogWatcher.DataCase
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LogWatcher.Repo, ownership_timeout: 600_000)

    if tags[:async] do
      raise "Don't use async: true"
      Ecto.Adapters.SQL.Sandbox.mode(LogWatcher.Repo, :manual)
    else
      # _ = Logger.error("setting shared sandbox mode for #{inspect(self())}")
      Ecto.Adapters.SQL.Sandbox.mode(LogWatcher.Repo, {:shared, self()})
    end

    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @spec assert_script_started(term(), String.t()) :: {reference(), [term()]}
  def assert_script_started(start_result, command_id) do
    {:ok, %{command_id: script_command_id, status: status, message: message, task_ref: task_ref}} =
      start_result

    assert script_command_id == command_id
    assert status == "running"
    assert String.contains?(message, "running on line")
    task_ref
  end

  @spec assert_script_errors(term(), String.t(), String.t() | [String.t()], String.t()) ::
          {reference(), [term()]}
  def assert_script_errors(
        start_result,
        command_id,
        expected_categories,
        expected_status \\ "completed"
      ) do
    {:ok,
     %{command_id: script_command_id, status: status, message: _message, task_ref: task_ref} =
       info} = start_result

    assert script_command_id == command_id
    assert status == expected_status
    errors = get_in(info, [:result, :errors])
    assert !is_nil(errors)
    first_error = hd(errors)
    assert !is_nil(first_error)
    categories = List.wrap(expected_categories)
    assert Enum.member?(categories, first_error.category)
    task_ref
  end

  @spec await_task(reference() | integer(), integer()) ::
          {:ok, term()} | {:error, :timeout}
  def await_task(task_ref, timeout) when is_reference(task_ref) do
    _ = Logger.debug("await_task task_ref #{inspect(task_ref)}")
    result = CommandManager.await(task_ref, timeout)
    _ = Logger.debug("await_task returned #{inspect(result)}")
    result
  end

  def await_task(job_id, timeout) when is_integer(job_id) do
    _ = Logger.debug("await_task job #{job_id}")
    result = CommandManager.await(job_id, timeout)
    _ = Logger.debug("await_task returned #{inspect(result)}")
    result
  end

  @spec await_os_process(integer(), integer()) :: :ok | {:error, :timeout}
  def await_os_process(os_pid, timeout) do
    _ = Logger.debug("await_os_process #{os_pid}")
    proc_file = "/proc/#{os_pid}"

    if File.exists?(proc_file) do
      expiry = System.monotonic_time() + timeout
      wait_on_proc_file_until(proc_file, expiry)
    else
      :ok
    end
  end

  @spec wait_on_proc_file_until(String.t(), integer()) :: :ok | {:error, :timeout}
  def wait_on_proc_file_until(proc_file, expiry) do
    time_now = System.monotonic_time()
    _ = Process.sleep(100)

    if File.exists?(proc_file) do
      if time_now <= expiry do
        wait_on_proc_file_until(proc_file, expiry)
      else
        {:error, :timeout}
      end
    else
      :ok
    end
  end

  # Beware that if the test process terminates while the worker is using
  # the connection, the connection will be taken away from the worker,
  # which will error. Therefore it is important to guarantee the work is
  # done before the test concludes.
  def await_pipeline(), do: Process.sleep(500)
end
