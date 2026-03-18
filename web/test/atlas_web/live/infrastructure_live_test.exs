defmodule AtlasWeb.InfrastructureLiveTest do
  use AtlasWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user =
      Atlas.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "infra@example.com",
        password: "Testpass!23",
        password_confirmation: "Testpass!23"
      })
      |> Ash.create!(authorize?: false)

    {:ok, credential} =
      Atlas.Providers.Credential.create(%{
        provider_type: :fly,
        name: "Test Provider",
        api_token: "test_token"
      })

    conn = conn |> log_in_user(user)
    %{conn: conn, user: user, credential: credential}
  end

  describe "Index" do
    test "renders infrastructure index", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/infrastructure")
      assert has_element?(view, "h1", "Infrastructure")
    end

    test "lists apps", %{conn: conn, credential: credential} do
      {:ok, _} =
        Atlas.Infrastructure.App.create(%{
          provider_id: "app1",
          name: "test-app",
          provider_type: :fly,
          credential_id: credential.id
        })

      {:ok, view, _html} = live(conn, ~p"/infrastructure")
      assert has_element?(view, "a", "test-app")
    end
  end

  describe "AppShow" do
    test "shows app details", %{conn: conn, credential: credential} do
      {:ok, app} =
        Atlas.Infrastructure.App.create(%{
          provider_id: "app1",
          name: "detail-app",
          provider_type: :fly,
          credential_id: credential.id
        })

      {:ok, view, _html} = live(conn, ~p"/infrastructure/apps/#{app.id}")
      assert has_element?(view, "h1 *", "detail-app")
    end

    test "lists machines for an app", %{conn: conn, credential: credential} do
      {:ok, app} =
        Atlas.Infrastructure.App.create(%{
          provider_id: "app2",
          name: "machine-app",
          provider_type: :fly,
          credential_id: credential.id
        })

      {:ok, _machine} =
        Atlas.Infrastructure.Machine.create(%{
          provider_id: "machine1",
          name: "worker-1",
          region: "iad",
          status: :started,
          app_id: app.id,
          credential_id: credential.id
        })

      {:ok, view, _html} = live(conn, ~p"/infrastructure/apps/#{app.id}")
      assert has_element?(view, "a", "worker-1")
    end
  end

  describe "MachineShow" do
    test "shows machine details", %{conn: conn, credential: credential} do
      {:ok, app} =
        Atlas.Infrastructure.App.create(%{
          provider_id: "app3",
          name: "machine-detail-app",
          provider_type: :fly,
          credential_id: credential.id
        })

      {:ok, machine} =
        Atlas.Infrastructure.Machine.create(%{
          provider_id: "machine2",
          name: "web-1",
          region: "iad",
          cpu_kind: "shared",
          cpus: 2,
          memory_mb: 512,
          status: :started,
          app_id: app.id,
          credential_id: credential.id
        })

      {:ok, view, _html} = live(conn, ~p"/infrastructure/machines/#{machine.id}")
      assert has_element?(view, "h1 *", "web-1")
    end
  end

  defp log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
