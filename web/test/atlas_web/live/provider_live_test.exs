defmodule AtlasWeb.ProviderLiveTest do
  use AtlasWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user =
      Atlas.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "test@example.com",
        password: "Testpass!23",
        password_confirmation: "Testpass!23"
      })
      |> Ash.create!(authorize?: false)

    conn = conn |> log_in_user(user)
    %{conn: conn, user: user}
  end

  describe "Index" do
    test "shows empty state when no providers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/providers")
      assert has_element?(view, "h1", "Providers")
      assert has_element?(view, "h3", "No providers configured")
    end

    test "lists providers when they exist", %{conn: conn} do
      {:ok, _} =
        Atlas.Providers.Credential.create(%{
          provider_type: :fly,
          name: "My Fly Account",
          api_token: "test_token"
        })

      {:ok, view, _html} = live(conn, ~p"/providers")
      assert has_element?(view, "a", "My Fly Account")
    end
  end

  describe "FormLive" do
    test "renders new provider form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/providers/new")
      assert has_element?(view, "h1", "New Provider")
    end

    test "creates a new provider", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/providers/new")

      view
      |> form("form", %{
        form: %{
          provider_type: "fly",
          name: "Test Fly",
          api_token: "fo1_test",
          org_slug: "personal",
          sync_interval_seconds: "60"
        }
      })
      |> render_submit()

      {path, _flash} = assert_redirect(view)
      assert path =~ "/providers/"
    end

    test "renders edit form for existing provider", %{conn: conn} do
      {:ok, credential} =
        Atlas.Providers.Credential.create(%{
          provider_type: :fly,
          name: "Edit Me",
          api_token: "test_token"
        })

      {:ok, view, _html} = live(conn, ~p"/providers/#{credential.id}/edit")
      assert has_element?(view, "h1", "Edit Provider")
    end
  end

  describe "Show" do
    test "shows provider details", %{conn: conn} do
      {:ok, credential} =
        Atlas.Providers.Credential.create(%{
          provider_type: :fly,
          name: "My Provider",
          api_token: "test_token",
          org_slug: "personal"
        })

      {:ok, view, _html} = live(conn, ~p"/providers/#{credential.id}")
      assert has_element?(view, "h1 *", "My Provider")
    end
  end

  defp log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
