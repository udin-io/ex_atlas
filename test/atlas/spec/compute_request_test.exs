defmodule Atlas.Spec.ComputeRequestTest do
  use ExUnit.Case, async: true

  alias Atlas.Spec.ComputeRequest

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
end
