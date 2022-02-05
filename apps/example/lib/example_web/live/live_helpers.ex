defmodule ExampleWeb.LiveHelpers do
  @moduledoc false
  import Phoenix.LiveView
  import Phoenix.LiveView.Helpers

  alias Phoenix.LiveView.JS
  alias Phoenix.LiveView.Socket

  @doc """
  Renders a live component inside a modal.

  The rendered modal receives a `:return_to` option to properly update
  the URL when the modal is closed.

  ## Examples

      <.modal return_to={Routes.user_index_path(@socket, :index)}>
        <.live_component
          module={ExampleWeb.UserLive.FormComponent}
          id={@user.id || :new}
          title={@page_title}
          action={@live_action}
          return_to={Routes.user_index_path(@socket, :index)}
          user: @user
        />
      </.modal>
  """
  def modal(assigns) do
    assigns = assign_new(assigns, :return_to, fn -> nil end)

    ~H"""
    <div id="modal" class="phx-modal fade-in" phx-remove={hide_modal()}>
      <div
        id="modal-content"
        class="phx-modal-content fade-in-scale"
        phx-click-away={JS.dispatch("click", to: "#close")}
        phx-window-keydown={JS.dispatch("click", to: "#close")}
        phx-key="escape"
      >
        <%= if @return_to do %>
          <%= live_patch "✖",
            to: @return_to,
            id: "close",
            class: "phx-modal-close",
            phx_click: hide_modal()
          %>
        <% else %>
         <a id="close" href="#" class="phx-modal-close" phx-click={hide_modal()}>✖</a>
        <% end %>

        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end

  # Notification handlers

  @max_notifications 5

  @doc """
  For session routes, we show up to @max_notifications, most recent first.
  """
  @spec handle_notification_detail(term(), Socket.t()) :: Socket.t()
  def handle_notification_detail({:event, %{data: event_data} = event}, socket) do
    notifications =
      Map.get(socket.assigns, :notifications, [])
      |> Enum.take(@max_notifications - 1)

    socket
    |> clear_flash(:info)
    |> assign(:notifications, [
      {"event-#{event.id}", "#{event_data.message}. Status is #{event_data.status}."}
      | notifications
    ])
  end

  def handle_notification_detail(_message, socket) do
    init_notifications(socket)
  end

  @doc """
  For user routes, we show one summary, with the count of recent notifications,
  for each session that has notifications. The session with the most recent
  notification is moved to the top if there are more than one.
  """
  def handle_notification_summary({:event, %{data: event_data} = event}, socket) do
    session_id = event.session.id
    session_name = event.session.name

    note_id = "session-#{session_id}"
    notifications = Map.get(socket.assigns, :notifications, [])

    other_notifications =
      case List.keytake(notifications, note_id, 0) do
        nil -> []
        {_note, rest} -> rest
      end

    counts = Map.get(socket.assigns, :session_notification_counts, %{})
    session_count = Map.get(counts, session_id, 0) + 1

    socket
    |> clear_flash(:info)
    |> assign(
      notifications: [
        {note_id,
         "#{session_name} has #{session_count} recent notifications. Status is #{event_data.status}."}
        | other_notifications
      ],
      session_notification_counts: Map.put(counts, session_id, session_count)
    )
  end

  def handle_notification_summary(_message, socket) do
    init_notifications(socket)
  end

  def init_notifications(socket) do
    socket
    |> assign_new(:subscriptions, fn -> MapSet.new() end)
    |> assign_new(:notifications, fn -> [] end)
    |> assign_new(:session_notification_counts, fn -> %{} end)
  end

  def update_subscriptions(socket, topics) do
    topics = MapSet.new(topics)

    for old <- MapSet.difference(socket.assigns.subscriptions, topics) |> MapSet.to_list() do
      Phoenix.PubSub.unsubscribe(LogWatcher.PubSub, old)
    end

    for new <- MapSet.difference(topics, socket.assigns.subscriptions) |> MapSet.to_list() do
      Phoenix.PubSub.subscribe(LogWatcher.PubSub, new)
    end

    assign(socket, :subscriptions, topics)
  end

  # Private functions

  defp hide_modal(js \\ %JS{}) do
    js
    |> JS.hide(to: "#modal", transition: "fade-out")
    |> JS.hide(to: "#modal-content", transition: "fade-out-scale")
  end
end
