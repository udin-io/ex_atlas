defmodule AtlasWeb.PageController do
  use AtlasWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/dashboard")
  end
end
