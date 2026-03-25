defmodule Atlas.Providers.Adapters.Fly.ClientTest do
  use Atlas.DataCase, async: false

  alias Atlas.Providers.Adapters.Fly.Client
  alias Atlas.Providers.Adapters.Fly.TokenCache
  alias Atlas.Providers.Credential

  @test_token "fm2_test_token_abc123"
  @fake_config_path "/tmp/nonexistent_fly_config_#{System.unique_integer([:positive])}.yml"

  setup do
    unique = System.unique_integer([:positive])
    server_name = :"client_test_cache_#{unique}"
    table_name = :"client_test_tokens_#{unique}"

    original_env = System.get_env("FLY_ACCESS_TOKEN")

    on_exit(fn ->
      if original_env do
        System.put_env("FLY_ACCESS_TOKEN", original_env)
      else
        System.delete_env("FLY_ACCESS_TOKEN")
      end
    end)

    %{server_name: server_name, table_name: table_name}
  end

  defp start_cache(ctx) do
    start_supervised!(
      {TokenCache,
       name: ctx.server_name,
       table_name: ctx.table_name,
       cli_detector_opts: [config_path: @fake_config_path]}
    )

    :ok
  end

  describe "new/1 - token source construction" do
    test "new(:cli) with available token returns ok with cli token_source", ctx do
      System.put_env("FLY_ACCESS_TOKEN", @test_token)
      start_cache(ctx)

      assert {:ok, %Client{token_source: :cli}} = Client.new(:cli, ctx.server_name)
    end

    test "new(:cli) when not found returns error", ctx do
      System.delete_env("FLY_ACCESS_TOKEN")
      start_cache(ctx)

      assert {:error, :cli_token_not_found} = Client.new(:cli, ctx.server_name)
    end

    test "new(%Credential{}) with valid credential returns ok", ctx do
      start_cache(ctx)

      {:ok, credential} =
        Credential.create(%{
          provider_type: :fly,
          name: "client-test-cred",
          api_token: "fly_secret_token_xyz"
        })

      assert {:ok, %Client{token_source: {:credential, id}}} =
               Client.new(credential, ctx.server_name)

      assert id == credential.id
    end

    test "new(%Credential{}) with missing credential returns error", ctx do
      start_cache(ctx)

      fake_credential = %Credential{
        id: Ash.UUID.generate(),
        provider_type: :fly,
        name: "nonexistent",
        api_token: "doesnt_matter"
      }

      assert {:error, _} = Client.new(fake_credential, ctx.server_name)
    end

    test "new(binary) always succeeds" do
      assert {:ok, %Client{token_source: :static}} = Client.new("some-api-token")
    end
  end

  describe "401 retry logic" do
    test "retries once on 401 with fresh token and succeeds", ctx do
      System.put_env("FLY_ACCESS_TOKEN", @test_token)
      start_cache(ctx)

      {:ok, client} = Client.new(:cli, ctx.server_name)

      # Stub: first call returns 401, second returns 200
      call_count = :counters.new(1, [:atomics])

      Req.Test.stub(:fly_client_test, fn conn ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          # First call - return 401
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
        else
          # After token refresh, update env to simulate new token
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"apps" => []}))
        end
      end)

      # Patch the client's req to use test plug
      client = %{
        client
        | req: Req.Request.merge_options(client.req, plug: {Req.Test, :fly_client_test})
      }

      assert {:ok, %{status: 200}} = Client.list_apps(client, "personal")
    end

    test "does not retry more than once - returns 401 if retry also fails", ctx do
      System.put_env("FLY_ACCESS_TOKEN", @test_token)
      start_cache(ctx)

      {:ok, client} = Client.new(:cli, ctx.server_name)

      Req.Test.stub(:fly_client_always_401, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
      end)

      client = %{
        client
        | req: Req.Request.merge_options(client.req, plug: {Req.Test, :fly_client_always_401})
      }

      assert {:ok, %{status: 401}} = Client.list_apps(client, "personal")
    end

    test "does not retry static tokens on 401" do
      {:ok, client} = Client.new("static-token")

      Req.Test.stub(:fly_client_static_401, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
      end)

      client = %{
        client
        | req: Req.Request.merge_options(client.req, plug: {Req.Test, :fly_client_static_401})
      }

      assert {:ok, %{status: 401}} = Client.list_apps(client, "personal")
    end

    test "passes through non-401 responses unchanged", ctx do
      System.put_env("FLY_ACCESS_TOKEN", @test_token)
      start_cache(ctx)

      {:ok, client} = Client.new(:cli, ctx.server_name)

      for status <- [200, 403, 500] do
        stub_name = :"fly_client_status_#{status}"

        Req.Test.stub(stub_name, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(%{"status" => status}))
        end)

        test_client = %{
          client
          | req: Req.Request.merge_options(client.req, plug: {Req.Test, stub_name})
        }

        assert {:ok, %{status: ^status}} = Client.list_apps(test_client, "personal")
      end
    end

    test "passes through error tuples unchanged", ctx do
      System.put_env("FLY_ACCESS_TOKEN", @test_token)
      start_cache(ctx)

      {:ok, client} = Client.new(:cli, ctx.server_name)

      Req.Test.stub(:fly_client_error, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      client = %{
        client
        | req: Req.Request.merge_options(client.req, plug: {Req.Test, :fly_client_error})
      }

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Client.list_apps(client, "personal")
    end
  end

  describe "integration - list_apps with credential retry recovery" do
    test "creates client from credential, retries on 401, succeeds", ctx do
      start_cache(ctx)

      {:ok, credential} =
        Credential.create(%{
          provider_type: :fly,
          name: "retry-test-cred",
          api_token: "fly_token_for_retry"
        })

      {:ok, client} = Client.new(credential, ctx.server_name)

      call_count = :counters.new(1, [:atomics])

      Req.Test.stub(:fly_client_cred_retry, fn conn ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"apps" => [%{"name" => "my-app"}]}))
        end
      end)

      client = %{
        client
        | req: Req.Request.merge_options(client.req, plug: {Req.Test, :fly_client_cred_retry})
      }

      assert {:ok, %{status: 200, body: %{"apps" => [%{"name" => "my-app"}]}}} =
               Client.list_apps(client, "personal")
    end
  end

  describe "list_orgs/1" do
    test "returns org nodes on success" do
      {:ok, client} = Client.new("test-token")

      Req.Test.stub(:fly_list_orgs_ok, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["query"] =~ "organizations"

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

      client = %{client | req: Req.Request.merge_options(client.req, plug: {Req.Test, :fly_list_orgs_ok})}

      assert {:ok, %{status: 200, body: body}} = Client.list_orgs(client)
      nodes = body["data"]["organizations"]["nodes"]
      assert length(nodes) == 2
      assert Enum.any?(nodes, &(&1["slug"] == "personal"))
    end

    test "handles error responses" do
      {:ok, client} = Client.new("bad-token")

      Req.Test.stub(:fly_list_orgs_err, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"errors" => [%{"message" => "Unauthorized"}]}))
      end)

      client = %{client | req: Req.Request.merge_options(client.req, plug: {Req.Test, :fly_list_orgs_err})}

      assert {:ok, %{status: 401}} = Client.list_orgs(client)
    end

    test "retries on 401 for non-static tokens", ctx do
      System.put_env("FLY_ACCESS_TOKEN", @test_token)
      start_cache(ctx)

      {:ok, client} = Client.new(:cli, ctx.server_name)
      call_count = :counters.new(1, [:atomics])

      Req.Test.stub(:fly_list_orgs_retry, fn conn ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{
            "data" => %{"organizations" => %{"nodes" => []}}
          }))
        end
      end)

      client = %{client | req: Req.Request.merge_options(client.req, plug: {Req.Test, :fly_list_orgs_retry})}

      assert {:ok, %{status: 200}} = Client.list_orgs(client)
    end
  end

  describe "all request functions use execute/2" do
    test "list_machines retries on 401", ctx do
      System.put_env("FLY_ACCESS_TOKEN", @test_token)
      start_cache(ctx)

      {:ok, client} = Client.new(:cli, ctx.server_name)
      call_count = :counters.new(1, [:atomics])

      Req.Test.stub(:fly_machines_retry, fn conn ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(401, "\"unauthorized\"")
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, "[]")
        end
      end)

      client = %{
        client
        | req: Req.Request.merge_options(client.req, plug: {Req.Test, :fly_machines_retry})
      }

      assert {:ok, %{status: 200}} = Client.list_machines(client, "my-app")
    end

    test "get_app retries on 401", ctx do
      System.put_env("FLY_ACCESS_TOKEN", @test_token)
      start_cache(ctx)

      {:ok, client} = Client.new(:cli, ctx.server_name)
      call_count = :counters.new(1, [:atomics])

      Req.Test.stub(:fly_get_app_retry, fn conn ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(401, "\"unauthorized\"")
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, ~s({"name":"app"}))
        end
      end)

      client = %{
        client
        | req: Req.Request.merge_options(client.req, plug: {Req.Test, :fly_get_app_retry})
      }

      assert {:ok, %{status: 200}} = Client.get_app(client, "my-app")
    end
  end
end
