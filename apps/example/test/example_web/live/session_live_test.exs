defmodule ExampleWeb.SessionLiveTest do
  use ExampleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import LogWatcher.SessionsFixtures

  @create_attrs %{
    name: "Test session",
    description: "A test session",
    log_dir: LogWatcher.session_log_dir(),
    gen: -1
  }
  @update_attrs %{gen: 0}
  @invalid_attrs %{
    name: nil,
    description: nil,
    gen: nil
  }

  defp create_session(context) do
    session_and_user_fixture()
  end

  describe "Index" do
    setup [:create_session]

    test "redirects to login page if user is not logged in", %{conn: conn} do
      {:error, {:redirect, %{to: "/users/log_in"}}} =
        live(conn, Routes.session_index_path(conn, :index))
    end

    test "lists all sessions", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, _index_live, html} = live(conn, Routes.session_index_path(conn, :index))

      assert html =~ "Listing Sessions"
    end

    test "saves new session", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, index_live, _html} = live(conn, Routes.session_index_path(conn, :index))

      assert index_live |> element("a", "New Session") |> render_click() =~
               "New Session"

      assert_patch(index_live, Routes.session_index_path(conn, :new))

      assert index_live
             |> form("#session-form", %{session: @invalid_attrs})
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _, html} =
        index_live
        |> form("#session-form", %{session: @create_attrs})
        |> render_submit()
        |> follow_redirect(conn, Routes.session_index_path(conn, :index))

      assert html =~ "Session created successfully"
    end

    test "updates session in listing", %{conn: conn, session: session, user: user} do
      conn = log_in_user(conn, user)
      {:ok, index_live, _html} = live(conn, Routes.session_index_path(conn, :index))

      assert index_live |> element("#session-#{session.id} a", "Edit") |> render_click() =~
               "Edit Session"

      assert_patch(index_live, Routes.session_index_path(conn, :edit, session))

      assert index_live
             |> form("#session-form", %{session: @invalid_attrs})
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _, html} =
        index_live
        |> form("#session-form", %{session: @update_attrs})
        |> render_submit()
        |> follow_redirect(conn, Routes.session_index_path(conn, :index))

      assert html =~ "Session updated successfully"
    end

    test "deletes session in listing", %{conn: conn, session: session, user: user} do
      conn = log_in_user(conn, user)
      {:ok, index_live, _html} = live(conn, Routes.session_index_path(conn, :index))

      assert index_live |> element("#session-#{session.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#session-#{session.id}")
    end
  end

  describe "Show" do
    setup [:create_session]

    test "displays session", %{conn: conn, session: session, user: user} do
      conn = log_in_user(conn, user)
      {:ok, _show_live, html} = live(conn, Routes.session_show_path(conn, :show, session))

      assert html =~ "Show Session"
    end

    test "updates session within modal", %{conn: conn, session: session, user: user} do
      conn = log_in_user(conn, user)
      {:ok, show_live, _html} = live(conn, Routes.session_show_path(conn, :show, session))

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Session"

      assert_patch(show_live, Routes.session_show_path(conn, :edit, session))

      assert show_live
             |> form("#session-form", %{session: @invalid_attrs})
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _, html} =
        show_live
        |> form("#session-form", %{session: @update_attrs})
        |> render_submit()
        |> follow_redirect(conn, Routes.session_show_path(conn, :show, session))

      assert html =~ "Session updated successfully"
    end
  end
end
