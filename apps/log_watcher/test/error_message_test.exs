defmodule LogWatcher.ErrorMessageTest do
  use ExUnit.Case

  test "raises an input error that includes a translated field" do
    assert_raise(
      LogWatcher.InputError,
      "Errors creating session: The log directory can't be blank.",
      fn ->
        LogWatcher.Sessions.create_session!("A name", "A description", "tag", "", 1)
      end
    )
  end
end
