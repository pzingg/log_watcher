defmodule LogWatcher.TypedStructTest do
  use LogWatcher.DataCase

  alias LogWatcher.Tasks.Task

  test "03 task new" do
    task = Task.new()

    assert is_nil(task.task_id)
  end

  test "04 task ecto types" do
    assert Enum.sort(Task.required_fields()) == [
             :archived?,
             :created_at,
             :gen,
             :log_dir,
             :log_prefix,
             :os_pid,
             :session_id,
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
             :log_dir,
             :log_prefix,
             :os_pid,
             :progress_counter,
             :progress_phase,
             :progress_total,
             :result,
             :running_at,
             :session_id,
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
             {:log_dir, :string},
             {:log_prefix, :string},
             {:os_pid, :integer},
             {:progress_counter, :integer},
             {:progress_phase, :string},
             {:progress_total, :integer},
             {:result, :map},
             {:running_at, :naive_datetime},
             {:session_id, :string},
             {:status, :string},
             {:task_id, :string},
             {:task_type, :string},
             {:updated_at, :naive_datetime}
           ]
  end
end
