defmodule LogWatcher.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `LogWatcher.Accounts` context.
  """

  alias LogWatcher.Accounts

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "valid password"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      first_name: "John",
      last_name: "Doe",
      email: unique_user_email()
    })
  end

  def user_fixture(attrs \\ %{}) do
    attrs = valid_user_attributes(attrs)
    {:ok, user} = Accounts.register_user(attrs)

    user
  end
end
