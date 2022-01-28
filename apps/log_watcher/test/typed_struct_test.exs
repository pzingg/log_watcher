defmodule LogWatcher.TypedStructTest do
  use LogWatcher.DataCase

  alias LogWatcher.Commands.Command

  test "03 task new" do
    task = Command.new()

    assert is_nil(task.command_id)
  end

  test "04 task ecto types" do
    assert Enum.sort(Command.required_fields()) == [
             :archived?,
             :command_id,
             :created_at,
             :gen,
             :log_dir,
             :log_prefix,
             :name,
             :os_pid,
             :session_id,
             :status,
             :updated_at
           ]

    assert Enum.sort(Command.all_fields()) == [
             :archived?,
             :command_id,
             :completed_at,
             :created_at,
             :errors,
             :gen,
             :last_message,
             :log_dir,
             :log_prefix,
             :name,
             :os_pid,
             :progress_counter,
             :progress_phase,
             :progress_total,
             :result,
             :running_at,
             :session_id,
             :status,
             :updated_at
           ]

    assert Enum.sort(Command.changeset_types()) == [
             {:archived?, :boolean},
             {:command_id, :string},
             {:completed_at, :naive_datetime},
             {:created_at, :naive_datetime},
             {:errors, {:array, :map}},
             {:gen, :integer},
             {:last_message, :string},
             {:log_dir, :string},
             {:log_prefix, :string},
             {:name, :string},
             {:os_pid, :integer},
             {:progress_counter, :integer},
             {:progress_phase, :string},
             {:progress_total, :integer},
             {:result, :map},
             {:running_at, :naive_datetime},
             {:session_id, :string},
             {:status, :string},
             {:updated_at, :naive_datetime}
           ]
  end
end
