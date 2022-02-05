defmodule ExampleWeb.InitAssigns do
  @moduledoc """
  Ensures common `assigns` are applied to all LiveViews attaching this hook.
  See https://blog.appsignal.com/2022/01/25/securing-your-phoenix-liveview-apps.html
  """
  import Phoenix.LiveView
  import ExampleWeb.LiveHelpers, only: [init_notifications: 1]

  alias LogWatcher.Accounts
  alias LogWatcher.Accounts.User

  def on_mount(:default, _params, _session, socket) do
    {:cont, assign(socket, page_title: "Example!") |> init_notifications()}
  end

  @doc """
  For authenticated live routes:

    1. Ensure we have a `User` struct set in the socket assigns at
      `:current_user`
    3. Set the empty assigns for `:subscriptions`, `:notifications`, and
      `:session_notification_counts` to manage notifications.
  """
  def on_mount(:user, _params, session, socket) do
    case assign_current_user(socket, session) do
      {:ok, socket} ->
        {:cont, init_notifications(socket)}

      {:error, :unauthorized} ->
        {:halt, redirect_unauthorized(socket)}
    end
  end

  def fetch_current_user(socket, session) do
    assign_new(socket, :current_user, fn ->
      Map.get(session, "user_token")
      |> Accounts.get_user_by_session_token()
    end)
  end

  defp assign_current_user(socket, session) do
    socket = fetch_current_user(socket, session)

    if Map.get(socket.assigns, :current_user) do
      {:ok, socket}
    else
      {:error, :unauthorized}
    end
  end

  defp redirect_unauthorized(socket) do
    socket
    |> put_flash(:error, "You must log in to access this page.")
    |> redirect(to: "/users/log_in")
  end
end
