defmodule LogWatcher.TypedStructTest do
  use LogWatcher.DataCase

  alias LogWatcher.Tasks.{Session, Task}

  test "01 session new" do
    session = Session.new()

    assert is_nil(session.session_id)
    assert session.gen == -1
  end

  test "02 session ecto types" do
    assert Enum.sort(Session.required_fields()) == [:description, :name, :session_id, :session_log_path]
    assert Enum.sort(Session.all_fields()) == [:description, :gen, :name, :session_id, :session_log_path]
    assert Enum.sort(Session.changeset_types()) == [
      {:description, :string},
      {:gen, :integer},
      {:name, :string},
      {:session_id, :string},
      {:session_log_path, :string}
    ]
  end

  test "03 task new" do
    task = Task.new()

    assert is_nil(task.task_id)
  end

  test "04 task ecto types" do
    assert Enum.sort(Task.required_fields()) == [
      :archived?,
      :created_at,
      :gen,
      :log_prefix,
      :os_pid,
      :session_id,
      :session_log_path,
      :status,
      :task_id,
      :task_type,
      :updated_at
    ]
    assert Enum.sort(Task.all_fields()) == [
      :archived?,
      :completed_at,
      :created_at,
      :errors,
      :gen,
      :last_message,
      :log_prefix,
      :os_pid,
      :progress_counter,
      :progress_phase,
      :progress_total,
      :result,
      :running_at,
      :session_id,
      :session_log_path,
      :status,
      :task_id,
      :task_type,
      :updated_at
    ]
    assert Enum.sort(Task.changeset_types()) == [
      {:archived?, :boolean},
      {:completed_at, :naive_datetime},
      {:created_at, :naive_datetime},
      {:errors, {:array, :map}},
      {:gen, :integer},
      {:last_message, :string},
      {:log_prefix, :string},
      {:os_pid, :integer},
      {:progress_counter, :integer},
      {:progress_phase, :string},
      {:progress_total, :integer},
      {:result, :map},
      {:running_at, :naive_datetime},
      {:session_id, :string},
      {:session_log_path, :string},
      {:status, :string},
      {:task_id, :string},
      {:task_type, :string},
      {:updated_at, :naive_datetime}
    ]
  end
end
