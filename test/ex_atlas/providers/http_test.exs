defmodule ExAtlas.Providers.HTTPTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Providers.HTTP

  @secret "tsec-http-61bd"
  @body %{
    "id" => "x",
    "env" => %{"TOKEN" => @secret},
    "template" => %{"env" => %{"K" => @secret}}
  }

  describe "handle_response/3" do
    test "an error status keeps env out of the error, for every provider that shares it" do
      for provider <- [:runpod, :vast, :lambda_labs] do
        response = {:ok, %Req.Response{status: 400, body: @body}}

        assert {:error, %ExAtlas.Error{provider: ^provider, raw: raw} = error} =
                 HTTP.handle_response(response, 200..299, provider)

        assert raw == %{"id" => "x", "template" => %{}}
        refute inspect(error, structs: false) =~ @secret
      end
    end

    test "a success status returns the body whole" do
      response = {:ok, %Req.Response{status: 200, body: @body}}
      assert {:ok, @body} = HTTP.handle_response(response, 200..299, :runpod)
    end
  end

  describe "handle_response/3 with a Req exception that carries the response body" do
    @echo ~s({"env": {"K": "#{@secret}"}})

    defp req_error(plug, options) do
      [plug: plug, retry: false]
      |> Keyword.merge(options)
      |> Req.new()
      |> Req.get(url: "http://atlas.test/x")
      |> HTTP.handle_response(200..299, :runpod)
    end

    defp prints?(error) do
      Enum.any?(
        [inspect(error, structs: false, limit: :infinity), Exception.message(error)],
        &(&1 =~ @secret)
      )
    end

    test "a body that fails to decompress is withheld" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.send_resp(400, @echo)
      end

      assert {:error, %ExAtlas.Error{} = error} = req_error(plug, compressed: true)

      refute prints?(error)
      assert %{kind: :transport, raw: nil} = error
      assert error.message =~ "Req.DecompressError"
    end

    test "a caller's decoder that returns the body in its exception is withheld" do
      codec = fn body -> {:error, %JSON.DecodeError{message: "bad", data: body, offset: 0}} end
      plug = fn conn -> Req.Test.json(%{conn | status: 400}, %{"env" => %{"K" => @secret}}) end

      assert {:error, %ExAtlas.Error{} = error} = req_error(plug, decoders: [json: codec])

      refute prints?(error)
      assert %{kind: :provider, raw: nil} = error
    end

    test "control: a transport timeout keeps its reason" do
      plug = fn conn -> Req.Test.transport_error(conn, :timeout) end

      assert {:error,
              %ExAtlas.Error{kind: :transport, raw: %Req.TransportError{reason: :timeout}} = error} =
               req_error(plug, [])

      assert error.message == "timeout"
    end
  end

  describe "handle_response/3 with an env deeper in the error body" do
    defp error_raw(body, status \\ 409) do
      {:error, %ExAtlas.Error{} = error} =
        HTTP.handle_response({:ok, %Req.Response{status: status, body: body}}, 200..299, :runpod)

      refute inspect(error, structs: false, limit: :infinity) =~ @secret
      error.raw
    end

    test "a wrapper map, a list of maps and three levels deep" do
      assert error_raw(%{"conflict" => %{"env" => %{"K" => @secret}, "id" => "e1"}}) ==
               %{"conflict" => %{"id" => "e1"}}

      assert error_raw(%{"errors" => [%{"resource" => %{"env" => @secret, "n" => 1}}, "text"]}) ==
               %{"errors" => [%{"resource" => %{"n" => 1}}, "text"]}

      assert error_raw(%{"a" => %{"b" => %{"c" => %{"env" => @secret, "keep" => true}}}}) ==
               %{"a" => %{"b" => %{"c" => %{"keep" => true}}}}
    end

    test "an atom-keyed body (decode_json keys: :atoms)" do
      assert error_raw(%{endpoint: %{env: %{K: @secret}, id: "e1"}}, 500) ==
               %{endpoint: %{id: "e1"}}
    end

    test "an atom-keyed RFC 9457 body drops the rejected value too" do
      body = %{errors: [%{location: "env", message: "bad", value: @secret}], detail: "invalid"}

      assert error_raw(body, 400) == %{
               errors: [%{location: "env", message: "bad"}],
               detail: "invalid"
             }
    end

    test "a wrapped errors list drops the rejected value too" do
      body = %{"error" => %{"errors" => [%{"message" => "bad", "value" => @secret}]}}
      assert error_raw(body, 422) == %{"error" => %{"errors" => [%{"message" => "bad"}]}}
    end

    test "a body with both a string and an atom errors list drops value from each" do
      body = %{
        "errors" => [%{"message" => "a", "value" => @secret}],
        errors: [%{message: "b", value: @secret}]
      }

      assert error_raw(body, 422) == %{
               "errors" => [%{"message" => "a"}],
               errors: [%{message: "b"}]
             }
    end

    test "a field named value outside an errors list stays" do
      body = %{"detail" => "no", "limit" => %{"value" => 3}}
      assert error_raw(body, 422) == body
    end

    test "a 3xx status keeps env out of the error" do
      assert error_raw(%{"env" => @secret, "location" => "/x"}, 302) == %{"location" => "/x"}
    end

    test "a body with no env keeps its raw whole, and a field named environment stays" do
      body = %{"detail" => "no", "nested" => [%{"environment" => "prod", "id" => 1}]}
      assert error_raw(body, 404) == body
    end

    test "a body that is not a map or list passes through" do
      assert error_raw("bad gateway", 502) == "bad gateway"
    end
  end

  describe "drop_env/1" do
    test "drops env and the env of an embedded template, and nothing else" do
      assert HTTP.drop_env(@body) == %{"id" => "x", "template" => %{}}
    end

    test "drops env from each pod of a workers list, and leaves a workers count map alone" do
      pods = [%{"id" => "p1", "env" => %{"K" => @secret}}, %{"id" => "p2"}]

      assert HTTP.drop_env(%{"id" => "x", "workers" => pods}) ==
               %{"id" => "x", "workers" => [%{"id" => "p1"}, %{"id" => "p2"}]}

      counts = %{"id" => "x", "workers" => %{"min" => 0, "max" => 3}}
      assert HTTP.drop_env(counts) == counts
    end

    test "drops env from each entry of a list body" do
      assert HTTP.drop_env([@body, %{"id" => "y"}]) == [
               %{"id" => "x", "template" => %{}},
               %{"id" => "y"}
             ]
    end

    test "feeds its own output back unchanged" do
      once = HTTP.drop_env(@body)
      assert HTTP.drop_env(once) == once
    end

    test "leaves a template that is not a map, and a body that is not a map, as they are" do
      assert HTTP.drop_env(%{"template" => "t1"}) == %{"template" => "t1"}
      assert HTTP.drop_env("bad gateway") == "bad gateway"
      assert HTTP.drop_env([1, "x"]) == [1, "x"]
      assert HTTP.drop_env(nil) == nil
    end
  end
end
