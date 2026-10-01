defmodule ExAtlas.Spec.TemplateRequestTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Spec.TemplateRequest

  test "builds a request from name and image, leaving everything else unset" do
    req = TemplateRequest.new!(name: "trainer-v7", image: "ghcr.io/acme/trainer:7")

    assert %TemplateRequest{
             name: "trainer-v7",
             ports: [],
             env: %{},
             container_disk_gb: nil,
             volume_gb: nil,
             command: nil,
             serverless: false,
             ssh: nil,
             jupyter: nil,
             provider_opts: %{}
           } = req
  end

  test "accepts every option" do
    req =
      TemplateRequest.new!(
        name: "t",
        image: "i",
        ports: [{8000, :http}],
        env: %{"A" => "1"},
        container_disk_gb: 80,
        volume_gb: 100,
        command: ["python", "train.py"],
        serverless: true,
        ssh: false,
        jupyter: false,
        provider_opts: %{category: "AMD"}
      )

    assert %{ports: [{8000, :http}], ssh: false, jupyter: false, serverless: true} = req
  end

  test "name and image are required" do
    assert {:error, %NimbleOptions.ValidationError{}} = TemplateRequest.new(image: "i")
    assert {:error, %NimbleOptions.ValidationError{}} = TemplateRequest.new(name: "n")
    assert_raise NimbleOptions.ValidationError, fn -> TemplateRequest.new!(name: "n") end
  end

  test "rejects an unknown option" do
    assert {:error, %NimbleOptions.ValidationError{}} =
             TemplateRequest.new(name: "n", image: "i", bogus: 1)
  end
end
