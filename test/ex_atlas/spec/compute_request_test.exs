defmodule ExAtlas.Spec.ComputeRequestTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Spec.ComputeRequest

  test "new!/1 builds with defaults" do
    req = ComputeRequest.new!(gpu: :h100)
    assert req.gpu == :h100
    assert req.gpu_count == 1
    assert req.cloud_type == :any
    assert req.spot == false
    assert req.auth == :none
  end

  test "new!/1 raises without :gpu" do
    assert_raise NimbleOptions.ValidationError, fn ->
      ComputeRequest.new!(image: "x")
    end
  end

  test "new/1 returns error tuple for invalid cloud_type" do
    assert {:error, %NimbleOptions.ValidationError{}} =
             ComputeRequest.new(gpu: :h100, cloud_type: :hybrid)
  end

  test "new!/1 accepts a map" do
    req = ComputeRequest.new!(%{gpu: :h100, spot: true})
    assert req.spot == true
  end

  test "new!/1 defaults to no command and to self-termination" do
    req = ComputeRequest.new!(gpu: :h100)
    assert req.command == nil
    assert req.self_terminate == true
  end

  test "new!/1 takes a command as a list of strings" do
    req = ComputeRequest.new!(gpu: :h100, command: ["/app/train.sh", "--epochs", "3"])
    assert req.command == ["/app/train.sh", "--epochs", "3"]
  end

  test "new/1 rejects a command that is not a list of strings" do
    assert {:error, %NimbleOptions.ValidationError{}} =
             ComputeRequest.new(gpu: :h100, command: "/app/train.sh")
  end

  describe "env validation errors" do
    test "a non-string value returns an error that holds no env value" do
      assert {:error, %NimbleOptions.ValidationError{key: :env, value: nil} = error} =
               ComputeRequest.new(gpu: :h100, env: %{"K" => "v-secret-71a4", "N" => 1})

      assert Exception.message(error) =~ ~s(:env)
      assert Exception.message(error) =~ ~s("N")
      refute inspect(error) =~ "v-secret-71a4"
    end

    test "an env that is not a map returns an error that does not echo it" do
      assert {:error, %NimbleOptions.ValidationError{key: :env, value: nil} = error} =
               ComputeRequest.new(gpu: :h100, env: "v-secret-71a4")

      refute inspect(error) =~ "v-secret-71a4"
    end

    test "a non-string name is refused without printing the env" do
      assert {:error, %NimbleOptions.ValidationError{key: :env, value: nil} = error} =
               ComputeRequest.new(gpu: :h100, env: %{1 => "v-secret-71a4"})

      refute inspect(error) =~ "v-secret-71a4"
    end

    test "new!/1 raises the same value-free error" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          ComputeRequest.new!(gpu: :h100, env: %{"K" => "v-secret-71a4", "N" => 1})
        end

      assert error.key == :env
      refute inspect(error) =~ "v-secret-71a4"
    end

    test "a map of strings is accepted as before (control)" do
      assert {:ok, %ComputeRequest{env: %{"K" => "v-secret-71a4"}}} =
               ComputeRequest.new(gpu: :h100, env: %{"K" => "v-secret-71a4"})
    end
  end
end
