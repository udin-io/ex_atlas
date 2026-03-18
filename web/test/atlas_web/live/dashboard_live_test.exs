defmodule AtlasWeb.DashboardLiveTest do
  use AtlasWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user =
      Atlas.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "dashboard@example.com",
        password: "Testpass!23",
        password_confirmation: "Testpass!23"
      })
      |> Ash.create!(authorize?: false)

    conn = conn |> log_in_user(user)
    %{conn: conn, user: user}
  end

  test "renders dashboard with stats", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")
    assert has_element?(view, "h1", "Dashboard")
    assert has_element?(view, ".stat-title", "Providers")
    assert has_element?(view, ".stat-title", "Apps")
    assert has_element?(view, ".stat-title", "Machines")
  end

  test "shows providers in dashboard", %{conn: conn} do
    {:ok, _} =
      Atlas.Providers.Credential.create(%{
        provider_type: :fly,
        name: "Dashboard Provider",
        api_token: "test_token"
      })

    {:ok, view, _html} = live(conn, ~p"/dashboard")
    assert has_element?(view, "a", "Dashboard Provider")
  end

  defp log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
