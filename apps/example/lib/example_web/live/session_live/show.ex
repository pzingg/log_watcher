defmodule ExampleWeb.SessionLive.Show do
  @moduledoc false
  use ExampleWeb, :live_view

  alias LogWatcher.Sessions
  alias LogWatcher.Sessions.Session

  @impl true
  @doc false
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  @doc """
  When the session changes, adjust our PubSub subscriptions.
  """
  def handle_params(%{"id" => session_id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:session, Sessions.get_session!(session_id))
     |> update_subscriptions([Session.session_topic(session_id)])}
  end

  @impl true
  @doc """
  If we receive an `{:event, event}` message from PubSub,
  we pass it onto `LiveHelpers.handle_notification_detail`.
  """
  def handle_info(message, socket) do
    {:noreply, handle_notification_detail(message, socket)}
  end

  # Private functions

  defp page_title(:show), do: "Show Session"
  defp page_title(:edit), do: "Edit Session"
end
