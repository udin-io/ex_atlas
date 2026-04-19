defmodule Atlas.ErrorTest do
  use ExUnit.Case, async: true

  test "from_response maps 401 to :unauthorized" do
    err = Atlas.Error.from_response(401, %{"error" => "bad key"}, :runpod)
    assert %Atlas.Error{kind: :unauthorized, provider: :runpod, status: 401} = err
    assert err.message == "bad key"
  end

  test "from_response maps 404 to :not_found" do
    err = Atlas.Error.from_response(404, %{"message" => "gone"}, :runpod)
    assert err.kind == :not_found
    assert err.message == "gone"
  end

  test "from_response maps 429 to :rate_limited" do
    err = Atlas.Error.from_response(429, "slow down", :runpod)
    assert err.kind == :rate_limited
    assert err.message == "slow down"
  end

  test "from_response extracts nested error messages" do
    body = %{"errors" => [%{"message" => "deep error"}]}
    err = Atlas.Error.from_response(400, body, :runpod)
    assert err.message == "deep error"
  end

  test "Exception.message/1 renders a useful string" do
    err = Atlas.Error.new(:unauthorized, provider: :runpod, message: "bad key", status: 401)
    assert Exception.message(err) == "[runpod] unauthorized (HTTP 401): bad key"
  end
end
