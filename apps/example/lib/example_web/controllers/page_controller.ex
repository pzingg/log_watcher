defmodule ExampleWeb.PageController do
  @moduledoc false
  use ExampleWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end
end
