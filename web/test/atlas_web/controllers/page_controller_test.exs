defmodule AtlasWeb.PageControllerTest do
  use AtlasWeb.ConnCase

  test "GET / redirects to /dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn, 302) == "/dashboard"
  end
end
