defmodule AtlasWeb.TopologyLiveTest do
  use AtlasWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user =
      Atlas.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "topology@example.com",
        password: "Testpass!23",
        password_confirmation: "Testpass!23"
      })
      |> Ash.create!(authorize?: false)

    conn = conn |> log_in_user(user)
    %{conn: conn, user: user}
  end

  test "renders topology page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/topology")
    assert has_element?(view, "h1", "Topology")
    assert has_element?(view, "#topology-graph")
  end

  test "pushes topology data with infrastructure", %{conn: conn} do
    {:ok, credential} =
      Atlas.Providers.Credential.create(%{
        provider_type: :fly,
        name: "Topo Provider",
        api_token: "test_token"
      })

    {:ok, app} =
      Atlas.Infrastructure.App.create(%{
        provider_id: "topo-app",
        name: "topo-test",
        provider_type: :fly,
        credential_id: credential.id
      })

    {:ok, _machine} =
      Atlas.Infrastructure.Machine.create(%{
        provider_id: "topo-machine",
        name: "worker-1",
        status: :started,
        app_id: app.id,
        credential_id: credential.id
      })

    {:ok, view, _html} = live(conn, ~p"/topology")
    assert has_element?(view, "#topology-graph")
  end

  defp log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
