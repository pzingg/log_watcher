defmodule LogWatcher.ErrorMessageTest do
  use ExUnit.Case

  test "raises an input error that includes a translated field" do
    assert_raise(
      LogWatcher.InputError,
      "Errors creating session (id: S001): The log path can't be blank.",
      fn ->
        LogWatcher.Tasks.create_session!("S001", "A name", "A description", "", 1)
      end
    )
  end
end
