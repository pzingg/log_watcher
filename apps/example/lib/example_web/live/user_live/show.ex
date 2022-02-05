defmodule ExampleWeb.UserLive.Show do
  @moduledoc false
  use ExampleWeb, :live_view

  alias LogWatcher.Accounts
  alias LogWatcher.Accounts.User

  @impl true
  @doc false
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  @doc """
  When the user changes, adjust our PubSub subscriptions.
  """
  def handle_params(%{"id" => user_id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:user, Accounts.get_user!(user_id))
     |> update_subscriptions([User.user_topic(user_id)])}
  end

  @impl true
  @doc """
  If we receive an `{:event, event}` message from PubSub,
  we pass it onto `LiveHelpers.handle_notification_summary`.
  """
  def handle_info(message, socket) do
    {:noreply, handle_notification_summary(message, socket)}
  end

  defp page_title(:show), do: "Show User"
  defp page_title(:edit), do: "Edit User"
end
