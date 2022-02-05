defmodule ExampleWeb.CommandLive.New do
  @moduledoc false
  use ExampleWeb, :live_view

  require Logger

  alias LogWatcher.CommandManager
  alias LogWatcher.Commands.Request
  alias LogWatcher.Sessions

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, %{"id" => id}) do
    request = %Request{command_id: Ecto.ULID.generate()}

    socket
    |> assign(:page_title, "New Command")
    |> assign(:session, Sessions.get_session!(id))
    |> assign(:request, request)
    |> assign(:changeset, Request.changeset(request, %{num_lines: 6}))
  end

  @impl true
  def handle_event("validate", %{"request" => request_params}, socket) do
    changeset =
      socket.assigns.request
      |> Request.changeset(request_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"request" => request_params}, socket) do
    save_command(socket, socket.assigns.live_action, request_params)
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

  defp save_command(socket, :new, request_params) do
    result =
      socket.assigns.request
      |> Request.changeset(request_params)
      |> Ecto.Changeset.apply_action(:insert)

    case result do
      {:ok, request} ->
        command_args =
          request
          |> Request.to_command_args()
          |> Map.put(:await_running, false)

        script_result =
          CommandManager.start_script(
            socket.assigns.session,
            request.command_id,
            request.command_name,
            command_args
          )

        {level, note} = to_flash(script_result)

        {:noreply,
         socket
         |> put_flash(level, note)
         |> push_redirect(to: Routes.session_show_path(socket, :show, socket.assigns.session))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  defp to_flash({:ok, %{message: message, status: status} = result}) do
    case Map.get(result, :errors) do
      [error] -> {:error, "#{error.message}. Status is #{status}"}
      _ -> {:info, "#{message}. Status is #{status}"}
    end
  end

  defp to_flash(result) do
    {:error, "Could not read status of command result: #{inspect(result)}"}
  end
end
