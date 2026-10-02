defmodule ExAtlas.ErrorTest do
  use ExUnit.Case, async: true

  test "from_response maps 401 to :unauthorized" do
    err = ExAtlas.Error.from_response(401, %{"error" => "bad key"}, :runpod)
    assert %ExAtlas.Error{kind: :unauthorized, provider: :runpod, status: 401} = err
    assert err.message == "bad key"
  end

  test "from_response keeps no body for a success status the caller did not expect" do
    # A 200 or 202 answers with the resource, not an error: RunPod's pod body
    # carries the pod's env.
    body = %{"id" => "p1", "env" => %{"HF_TOKEN" => "hf-secret-5d1"}}

    for status <- [200, 202] do
      err = ExAtlas.Error.from_response(status, body, :runpod)
      assert err.status == status
      assert err.raw == nil
      refute inspect(err, structs: false, limit: :infinity) =~ "hf-secret-5d1"
    end

    # Control: an error status keeps its body.
    assert ExAtlas.Error.from_response(400, %{"detail" => "bad"}, :runpod).raw == %{
             "detail" => "bad"
           }
  end

  test "from_response maps 404 to :not_found" do
    err = ExAtlas.Error.from_response(404, %{"message" => "gone"}, :runpod)
    assert err.kind == :not_found
    assert err.message == "gone"
  end

  test "from_response maps 429 to :rate_limited" do
    err = ExAtlas.Error.from_response(429, "slow down", :runpod)
    assert err.kind == :rate_limited
    assert err.message == "slow down"
  end

  test "from_response extracts nested error messages" do
    body = %{"errors" => [%{"message" => "deep error"}]}
    err = ExAtlas.Error.from_response(400, body, :runpod)
    assert err.message == "deep error"
  end

  test "from_response reads an RFC 9457 problem detail" do
    body = %{"title" => "Not Found", "status" => 404, "detail" => "pod not found"}
    err = ExAtlas.Error.from_response(404, body, :runpod)
    assert err.kind == :not_found
    assert err.message == "pod not found"
  end

  test "from_response appends a problem's string errors to its detail" do
    body = %{
      "title" => "Bad Request",
      "status" => 400,
      "detail" => "Request validation failed.",
      "errors" => ["name: is required", "gpu.id: unknown GPU"]
    }

    err = ExAtlas.Error.from_response(400, body, :runpod)

    assert err.message ==
             "Request validation failed. (name: is required; gpu.id: unknown GPU)"
  end

  test "from_response names object errors by location and message, never value" do
    body = %{
      "title" => "Unprocessable Entity",
      "status" => 422,
      "detail" => "Request validation failed.",
      "errors" => [
        %{
          "location" => "body.env.ATLAS_SIGNING_SECRET",
          "message" => "too long",
          "value" => "s3cret"
        },
        %{"message" => "unknown GPU"},
        42
      ]
    }

    err = ExAtlas.Error.from_response(422, body, :runpod)

    assert err.message ==
             "Request validation failed. (body.env.ATLAS_SIGNING_SECRET: too long; unknown GPU)"

    refute err.message =~ "s3cret"
    refute inspect(err.raw) =~ "s3cret"
  end

  test "from_response reads a bare list of string errors" do
    err = ExAtlas.Error.from_response(400, %{"errors" => ["bad cursor"]}, :runpod)
    assert err.message == "bad cursor"
  end

  test "Exception.message/1 renders a useful string" do
    err = ExAtlas.Error.new(:unauthorized, provider: :runpod, message: "bad key", status: 401)
    assert Exception.message(err) == "[runpod] unauthorized (HTTP 401): bad key"
  end
end
