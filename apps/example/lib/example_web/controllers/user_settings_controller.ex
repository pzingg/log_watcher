defmodule ExampleWeb.UserSettingsController do
  @moduledoc false
  use ExampleWeb, :controller

  alias LogWatcher.Accounts

  plug(:assign_email_and_profile_changesets)

  def edit(conn, _params) do
    render(conn, "edit.html")
  end

  def update(conn, %{"action" => "update_profile"} = params) do
    %{"user" => user_params} = params
    user = conn.assigns.current_user

    case Accounts.update_user_profile(user, user_params) do
      {:ok, _applied_user} ->
        conn
        |> put_flash(
          :info,
          "Your profile settings have been updated."
        )
        |> redirect(to: Routes.user_settings_path(conn, :edit))

      {:error, changeset} ->
        render(conn, "edit.html", profile_changeset: changeset)
    end
  end

  def update(conn, %{"action" => "update_email"} = params) do
    %{"user" => user_params} = params
    user = conn.assigns.current_user

    case Accounts.apply_user_email(user, user_params) do
      {:ok, _applied_user} ->
        conn
        |> put_flash(
          :info,
          "A link to confirm your email change has been sent to the new address."
        )
        |> redirect(to: Routes.user_settings_path(conn, :edit))

      {:error, changeset} ->
        render(conn, "edit.html", email_changeset: changeset)
    end
  end

  defp assign_email_and_profile_changesets(conn, _opts) do
    user = conn.assigns.current_user

    conn
    |> assign(:email_changeset, Accounts.change_user_email(user))
    |> assign(:profile_changeset, Accounts.change_user_profile(user))
  end
end
