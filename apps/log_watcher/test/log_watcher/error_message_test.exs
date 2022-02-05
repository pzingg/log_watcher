defmodule LogWatcher.ErrorMessageTest do
  use LogWatcher.DataCase, async: false

  import LogWatcher.AccountsFixtures

  alias LogWatcher.Sessions

  test "raises an input error that includes a translated field" do
    user = user_fixture()

    assert_raise(
      LogWatcher.InputError,
      "Errors creating session: The log directory can't be blank.",
      fn ->
        Sessions.create_session!(%{
          user_id: user.id,
          name: "A name",
          description: "A description",
          log_dir: "",
          gen: :rand.uniform(10) - 1
        })
      end
    )
  end
end
