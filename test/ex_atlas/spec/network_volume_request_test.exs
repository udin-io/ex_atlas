defmodule ExAtlas.Spec.NetworkVolumeRequestTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Spec.NetworkVolumeRequest

  test "builds a request from name and size_gb, leaving region and tier unset" do
    req = NetworkVolumeRequest.new!(name: "datasets", size_gb: 200)

    assert req.name == "datasets"
    assert req.size_gb == 200
    assert req.region == nil
    assert req.tier == nil
    assert req.provider_opts == %{}
  end

  test "accepts region, both tiers and provider_opts" do
    for tier <- [:standard, :high_performance] do
      req =
        NetworkVolumeRequest.new!(
          name: "d",
          size_gb: 10,
          region: "EU-RO-1",
          tier: tier,
          provider_opts: %{x: 1}
        )

      assert %{region: "EU-RO-1", tier: ^tier, provider_opts: %{x: 1}} = req
    end
  end

  test "new/1 refuses a missing name, a missing size_gb and a zero size_gb" do
    assert {:error, %NimbleOptions.ValidationError{}} = NetworkVolumeRequest.new(size_gb: 10)
    assert {:error, %NimbleOptions.ValidationError{}} = NetworkVolumeRequest.new(name: "d")

    assert {:error, %NimbleOptions.ValidationError{}} =
             NetworkVolumeRequest.new(name: "d", size_gb: 0)
  end

  test "new/1 refuses an unknown tier" do
    assert {:error, %NimbleOptions.ValidationError{}} =
             NetworkVolumeRequest.new(name: "d", size_gb: 10, tier: :fast)
  end

  test "new!/1 raises on invalid input" do
    assert_raise NimbleOptions.ValidationError, fn -> NetworkVolumeRequest.new!(name: "d") end
  end
end
