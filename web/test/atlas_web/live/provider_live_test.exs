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

  describe "CLI Detection" do
    test "detect button shown for fly, hidden for runpod", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/providers/new")

      # Select fly → detect button appears
      view
      |> form("form", %{form: %{provider_type: "fly"}})
      |> render_change()

      assert has_element?(view, "button", "Detect from CLI")

      # Switch to runpod → detect button disappears
      view
      |> form("form", %{form: %{provider_type: "runpod"}})
      |> render_change()

      refute has_element?(view, "button", "Detect from CLI")
    end

    test "detect_cli_token success shows token detected", %{conn: conn} do
      original = System.get_env("FLY_ACCESS_TOKEN")

      on_exit(fn ->
        if original, do: System.put_env("FLY_ACCESS_TOKEN", original), else: System.delete_env("FLY_ACCESS_TOKEN")
      end)

      System.put_env("FLY_ACCESS_TOKEN", "fm2_detected_token_abc")

      {:ok, view, _html} = live(conn, ~p"/providers/new")

      view
      |> form("form", %{form: %{provider_type: "fly"}})
      |> render_change()

      view
      |> element("button", "Detect from CLI")
      |> render_click()

      assert has_element?(view, "[data-role=cli-detect-success]")
    end

    test "detect_cli_token failure shows error", %{conn: conn} do
      original = System.get_env("FLY_ACCESS_TOKEN")

      on_exit(fn ->
        if original, do: System.put_env("FLY_ACCESS_TOKEN", original), else: System.delete_env("FLY_ACCESS_TOKEN")
      end)

      System.delete_env("FLY_ACCESS_TOKEN")

      {:ok, view, _html} = live(conn, ~p"/providers/new")

      # Use a fake config path so file-based detection also fails
      send(view.pid, {:set_cli_detector_opts, [config_path: "/tmp/nonexistent_fly_config.yml"]})

      view
      |> form("form", %{form: %{provider_type: "fly"}})
      |> render_change()

      view
      |> element("button", "Detect from CLI")
      |> render_click()

      assert has_element?(view, "[data-role=cli-detect-error]")
    end

    test "fetch_orgs shows org badges", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/providers/new")

      # Stub the GraphQL call
      Req.Test.stub(:fly_graphql, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "data" => %{
            "organizations" => %{
              "nodes" => [
                %{"slug" => "personal", "name" => "Personal", "type" => "PERSONAL"},
                %{"slug" => "my-team", "name" => "My Team", "type" => "ORGANIZATION"}
              ]
            }
          }
        }))
      end)

      # Set up form with fly + token and inject test plug
      view
      |> form("form", %{form: %{provider_type: "fly", api_token: "test-token-123"}})
      |> render_change()

      # Inject req_options for test plug
      send(view.pid, {:set_req_options, [plug: {Req.Test, :fly_graphql}]})

      view
      |> element("button", "Fetch Organizations")
      |> render_click()

      assert has_element?(view, "[data-role=org-badge]", "personal")
      assert has_element?(view, "[data-role=org-badge]", "my-team")
    end

    test "clicking org badge fills org_slug field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/providers/new")

      Req.Test.stub(:fly_graphql, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "data" => %{
            "organizations" => %{
              "nodes" => [
                %{"slug" => "personal", "name" => "Personal", "type" => "PERSONAL"}
              ]
            }
          }
        }))
      end)

      view
      |> form("form", %{form: %{provider_type: "fly", api_token: "test-token-123"}})
      |> render_change()

      send(view.pid, {:set_req_options, [plug: {Req.Test, :fly_graphql}]})

      view
      |> element("button", "Fetch Organizations")
      |> render_click()

      view
      |> element("[data-role=org-badge]", "personal")
      |> render_click()

      # The org_slug input should now have the value
      assert view
             |> element("input[name='form[org_slug]']")
             |> render() =~ "personal"
    end

    test "switching provider type resets detection state", %{conn: conn} do
      original = System.get_env("FLY_ACCESS_TOKEN")

      on_exit(fn ->
        if original, do: System.put_env("FLY_ACCESS_TOKEN", original), else: System.delete_env("FLY_ACCESS_TOKEN")
      end)

      System.put_env("FLY_ACCESS_TOKEN", "fm2_detected_token_abc")

      {:ok, view, _html} = live(conn, ~p"/providers/new")

      # Select fly and detect
      view
      |> form("form", %{form: %{provider_type: "fly"}})
      |> render_change()

      view
      |> element("button", "Detect from CLI")
      |> render_click()

      assert has_element?(view, "[data-role=cli-detect-success]")

      # Switch to runpod
      view
      |> form("form", %{form: %{provider_type: "runpod"}})
      |> render_change()

      refute has_element?(view, "[data-role=cli-detect-success]")

      # Switch back to fly — should be clean
      view
      |> form("form", %{form: %{provider_type: "fly"}})
      |> render_change()

      refute has_element?(view, "[data-role=cli-detect-success]")
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
