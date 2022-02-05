defmodule ExampleWeb.CommandLiveTest do
  use ExampleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import LogWatcher.SessionsFixtures

  @create_attrs %{
    # command_id: Ecto.ULID.generate(),
    command_name: "create",
    script_file: "mock_command.R",
    space_type: "mixture",
    error: "",
    num_lines: 6
  }
  @invalid_attrs %{
    # command_id: nil,
    # command_name: nil,
    # script_file: nil,
    # space_type: nil,
    # error: nil,
    num_lines: nil
  }

  defp create_session(_) do
    session_and_user_fixture()
  end

  describe "New" do
    setup [:create_session]

    test "starts new command", %{conn: conn, session: session, user: user} do
      conn = log_in_user(conn, user)
      {:ok, new_live, _html} = live(conn, Routes.command_new_path(conn, :new, session))

      # No form_component here...
      # assert new_live |> element("a", "Send command") |> render_click() =~
      #         "Send command"

      assert new_live
             |> form("#request-form", %{request: @invalid_attrs})
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _, html} =
        new_live
        |> form("#request-form", %{request: @create_attrs})
        |> render_submit()
        |> follow_redirect(conn, Routes.session_show_path(conn, :show, session))

      assert html =~ "Launching Rscript for mock_command.R"
    end
  end
end
