defmodule AtlasWeb.PageController do
  use AtlasWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
