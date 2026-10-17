defmodule ExAtlas.Test.ApiTest do
  # The stub server the provider tests stand on. A check here that never fires
  # would leave every one of those tests green on a request that should fail it.
  use ExUnit.Case, async: true

  alias ExAtlas.Test.Api

  defp get(api, path, opts \\ []) do
    Req.get(api.base_url <> path, [plug: Api.plug(), retry: false] ++ opts)
  end

  defp send_ok(conn), do: Plug.Conn.send_resp(conn, 200, "")

  test "routes by method and path, and :name matches one segment" do
    api = Api.open()
    Api.stub(api, "GET", "/pods/:id", &Plug.Conn.send_resp(&1, 200, List.last(&1.path_info)))

    assert {:ok, %{status: 200, body: "p1"}} = get(api, "/pods/p1")
    assert {:ok, %{status: 500}} = get(api, "/pods/p1/extra")

    assert_raise ExUnit.AssertionError, ~r"unexpected request GET /pods/p1/extra", fn ->
      Api.verify!(api)
    end
  end

  test "a request to a route nobody registered answers 500 and fails the test" do
    api = Api.open()

    assert {:ok, %{status: 500}} = get(api, "/pods")

    assert_raise ExUnit.AssertionError, ~r"unexpected request GET /pods", fn ->
      Api.verify!(api)
    end
  end

  test "expect_once fails on a second request" do
    api = Api.open()
    Api.expect_once(api, "GET", "/a", &send_ok/1)

    assert {:ok, %{status: 200}} = get(api, "/a")
    assert {:ok, %{status: 500}} = get(api, "/a")
    assert_raise ExUnit.AssertionError, ~r"expected once, got 2", fn -> Api.verify!(api) end
  end

  test "expect_once and expect fail when no request arrives" do
    api = Api.open()
    Api.expect_once(api, "GET", "/a", &send_ok/1)
    Api.expect(api, "GET", "/b", &send_ok/1)

    assert_raise ExUnit.AssertionError, ~r"GET /a was expected but never requested", fn ->
      Api.verify!(api)
    end

    other = Api.open()
    Api.expect(other, "GET", "/b", &send_ok/1)

    assert_raise ExUnit.AssertionError, ~r"GET /b was expected but never requested", fn ->
      Api.verify!(other)
    end
  end

  test "expect takes any number of requests above none; stub takes none" do
    api = Api.open()
    Api.expect(api, "GET", "/a", &send_ok/1)
    Api.stub(api, "GET", "/b", &send_ok/1)

    assert {:ok, _} = get(api, "/a")
    assert {:ok, _} = get(api, "/a")
    assert :ok = Api.verify!(api)

    unused = Api.open()
    Api.stub(unused, "GET", "/b", &send_ok/1)
    assert :ok = Api.verify!(unused)
  end

  test "an assertion that fails inside a handler fails the test, though the client sees a 500" do
    api = Api.open()

    Api.stub(api, "GET", "/a", fn conn ->
      assert conn.method == "POST"
      send_ok(conn)
    end)

    assert {:ok, %{status: 500}} = get(api, "/a")
    assert_raise ExUnit.AssertionError, ~r"handler failed", fn -> Api.verify!(api) end
  end

  test "a handler that sets a response without sending it still answers" do
    api = Api.open()
    Api.stub(api, "GET", "/a", &Plug.Conn.resp(&1, 201, "made"))

    assert {:ok, %{status: 201, body: "made"}} = get(api, "/a")
  end

  test "unreachable answers every request with a refused connection" do
    api = Api.open()
    Api.unreachable(api)

    assert {:error, %Req.TransportError{reason: :econnrefused}} = get(api, "/anything")
    assert :ok = Api.verify!(api)
  end

  test "a followed redirect reaches the other API and fails the test" do
    elsewhere = Api.open()
    api = Api.open()

    Api.stub(api, "GET", "/a", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", elsewhere.base_url <> "/steal")
      |> Plug.Conn.send_resp(307, "")
    end)

    assert {:ok, %{status: 307}} = get(api, "/a", redirect: false)
    assert :ok = Api.verify!(elsewhere)

    assert {:ok, %{status: 500}} = get(api, "/a", redirect: true)

    assert_raise ExUnit.AssertionError, ~r"unexpected request GET /steal", fn ->
      Api.verify!(elsewhere)
    end
  end
end
