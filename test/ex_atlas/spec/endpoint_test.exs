defmodule ExAtlas.Spec.EndpointTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Spec.Endpoint

  test "inspect leaves out raw, which holds the endpoint's env secrets" do
    endpoint = %Endpoint{
      id: "ep1",
      provider: :runpod,
      name: "image-generator",
      raw: %{"env" => %{"HF_TOKEN" => "s3cr3t-value"}}
    }

    text = inspect(endpoint)
    assert text =~ "image-generator"
    refute text =~ "s3cr3t-value"
    refute text =~ "HF_TOKEN"
  end
end
