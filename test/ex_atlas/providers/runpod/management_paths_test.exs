defmodule ExAtlas.Providers.RunPod.ManagementPathsTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Test.Api

  alias ExAtlas.Providers.RunPod.{Billing, Endpoints, NetworkVolumes, Pods, Templates}

  setup do
    server = Api.open()
    ctx = %{api_key: "test-key", base_url: server.base_url, req_options: [plug: Api.plug()]}
    {:ok, server: server, ctx: ctx}
  end

  defp expect_path(server, method, path, body \\ "{}") do
    status = if method == "POST", do: 201, else: 200
    test_pid = self()

    Api.expect_once(server, method, path, fn conn ->
      send(test_pid, {:hit, method, path})

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(status, body)
    end)
  end

  # A pod id can come from a tracking record its writer chose (issue 138), so
  # it never adds a path segment.
  describe "a pod id is sent path-encoded" do
    test "get, stop, start and delete", %{server: server, ctx: ctx} do
      expect_path(server, "GET", "/pods/..%2Fx")
      assert {:ok, _} = Pods.get(ctx, "../x")

      expect_path(server, "POST", "/pods/..%2Fx/action", "{}")
      _ = Pods.stop(ctx, "../x")
      assert_received {:hit, "POST", "/pods/..%2Fx/action"}

      expect_path(server, "POST", "/pods/..%2Fx/action", "{}")
      _ = Pods.start(ctx, "../x")
      assert_received {:hit, "POST", "/pods/..%2Fx/action"}

      expect_path(server, "DELETE", "/pods/..%2Fx")
      assert {:ok, _} = Pods.delete(ctx, "../x")

      assert_received {:hit, "GET", "/pods/..%2Fx"}
      assert_received {:hit, "DELETE", "/pods/..%2Fx"}
    end
  end

  describe "serverless endpoints live under /serverless in REST v2" do
    test "create, get, list and delete", %{server: server, ctx: ctx} do
      expect_path(server, "POST", "/serverless")
      assert {:ok, _} = Endpoints.create(ctx, %{})
      assert_received {:hit, "POST", "/serverless"}

      expect_path(server, "GET", "/serverless/ep1")
      assert {:ok, _} = Endpoints.get(ctx, "ep1")
      assert_received {:hit, "GET", "/serverless/ep1"}

      expect_path(server, "GET", "/serverless", ~s({"endpoints": []}))
      assert {:ok, []} = Endpoints.list(ctx)
      assert_received {:hit, "GET", "/serverless"}

      expect_path(server, "DELETE", "/serverless/ep1")
      assert {:ok, _} = Endpoints.delete(ctx, "ep1")
      assert_received {:hit, "DELETE", "/serverless/ep1"}
    end
  end

  describe "templates live under /templates in REST v2" do
    test "create, list, get and delete", %{server: server, ctx: ctx} do
      expect_path(server, "POST", "/templates")
      assert {:ok, _} = Templates.create(ctx, %{})
      assert_received {:hit, "POST", "/templates"}

      expect_path(server, "GET", "/templates", ~s({"templates": []}))
      assert {:ok, []} = Templates.list(ctx)
      assert_received {:hit, "GET", "/templates"}

      expect_path(server, "GET", "/templates/t1")
      assert {:ok, _} = Templates.get(ctx, "t1")
      assert_received {:hit, "GET", "/templates/t1"}

      expect_path(server, "DELETE", "/templates/t1")
      assert {:ok, _} = Templates.delete(ctx, "t1")
      assert_received {:hit, "DELETE", "/templates/t1"}
    end
  end

  describe "list follows pagination.nextCursor" do
    for {module, path, key} <- [
          {Templates, "/templates", "templates"},
          {Endpoints, "/serverless", "endpoints"}
        ] do
      test "#{path} returns the entries of both pages", %{server: server, ctx: ctx} do
        Api.expect(server, "GET", unquote(path), fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)

          {entries, pagination} =
            case conn.query_params["cursor"] do
              nil -> {[%{"id" => "a"}], %{"nextCursor" => "c2", "hasNextPage" => true}}
              "c2" -> {[%{"id" => "b"}], %{"nextCursor" => nil, "hasNextPage" => false}}
            end

          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{unquote(key) => entries, "pagination" => pagination})
          )
        end)

        assert {:ok, [%{"id" => "a"}, %{"id" => "b"}]} = unquote(module).list(ctx)
      end
    end
  end

  describe "network volumes live under /network-volumes in REST v2" do
    test "create, list, get and delete", %{server: server, ctx: ctx} do
      expect_path(server, "POST", "/network-volumes")
      assert {:ok, _} = NetworkVolumes.create(ctx, %{})
      assert_received {:hit, "POST", "/network-volumes"}

      expect_path(server, "GET", "/network-volumes", ~s({"networkVolumes": []}))
      assert {:ok, _} = NetworkVolumes.list(ctx)
      assert_received {:hit, "GET", "/network-volumes"}

      expect_path(server, "GET", "/network-volumes/nv1")
      assert {:ok, _} = NetworkVolumes.get(ctx, "nv1")
      assert_received {:hit, "GET", "/network-volumes/nv1"}

      expect_path(server, "DELETE", "/network-volumes/nv1")
      assert {:ok, _} = NetworkVolumes.delete(ctx, "nv1")
      assert_received {:hit, "DELETE", "/network-volumes/nv1"}
    end
  end

  describe "billing" do
    test "pod usage uses the v2 path and passes the query through", %{server: server, ctx: ctx} do
      test_pid = self()

      Api.expect_once(server, "GET", "/billing/pods", fn conn ->
        send(test_pid, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, "{}")
      end)

      assert {:ok, _} = Billing.pods(ctx, podId: "pod_9")
      assert_received {:query, "podId=pod_9"}
    end

    test "serverless and network volume usage use the v2 paths", %{server: server, ctx: ctx} do
      expect_path(server, "GET", "/billing/serverless")
      assert {:ok, _} = Billing.endpoints(ctx)
      assert_received {:hit, "GET", "/billing/serverless"}

      expect_path(server, "GET", "/billing/network-volumes")
      assert {:ok, _} = Billing.network_volumes(ctx)
      assert_received {:hit, "GET", "/billing/network-volumes"}
    end
  end
end
