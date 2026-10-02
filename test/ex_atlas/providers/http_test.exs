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
