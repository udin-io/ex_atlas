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

  describe "env: values" do
    test "never print through inspect/1" do
      req =
        TemplateRequest.new!(
          name: "t",
          image: "i",
          env: %{"HF_TOKEN" => "hf-template-probe-2d6f"}
        )

      for opts <- [[], [structs: false]] do
        text = inspect(req, [limit: :infinity, printable_limit: :infinity] ++ opts)
        assert text =~ "TemplateRequest"
        refute text =~ "hf-template-probe-2d6f"
      end

      # Control: the provider still reads the value.
      assert TemplateRequest.env(req) == %{"HF_TOKEN" => "hf-template-probe-2d6f"}
    end

    test "an invalid env: names the key and holds no value" do
      for new <- [&TemplateRequest.new/1, &new_or_error/1] do
        assert {:error, %NimbleOptions.ValidationError{key: :env, value: nil} = error} =
                 new.(
                   name: "t",
                   image: "i",
                   env: %{"HF_TOKEN" => "hf-template-probe-2d6f", "N" => 1}
                 )

        assert Exception.message(error) =~ ~s("N")
        refute inspect(error) =~ "hf-template-probe-2d6f"
      end
    end
  end

  defp new_or_error(opts) do
    {:ok, TemplateRequest.new!(opts)}
  rescue
    error -> {:error, error}
  end
end
