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
end
