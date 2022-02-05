defmodule ExampleWeb.SessionLive.Index do
  @moduledoc false
  use ExampleWeb, :live_view

  alias LogWatcher.Accounts.User
  alias LogWatcher.Sessions
  alias LogWatcher.Sessions.Session

  @impl true
  @doc """
  We subscribe to all session events for the current user.
  """
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        update_subscriptions(socket, [User.user_topic(socket.assigns.current_user)])
      else
        socket
      end

    {:ok, assign(socket, :sessions, list_sessions(socket))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    session = Sessions.get_session!(id)
    {:ok, _} = Sessions.delete_session(session)

    {:noreply, assign(socket, :sessions, list_sessions(socket))}
  end

  @impl true
  @doc """
  If we receive an `{:event, event}` message from PubSub,
  we pass it onto `LiveHelpers.handle_notification_summary`.
  """
  def handle_info(message, socket) do
    {:noreply, handle_notification_summary(message, socket)}
  end

  # Private functions

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Session")
    |> assign(:session, Sessions.get_session!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Session")
    |> assign(:session, %Session{
      user_id: socket.assigns.current_user.id,
      tag: Session.generate_tag(),
      log_dir: LogWatcher.session_log_dir()
    })
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Sessions")
    |> assign(:session, nil)
  end

  defp list_sessions(socket) do
    Sessions.list_sessions_for_user(socket.assigns.current_user)
  end
end
