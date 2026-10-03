defmodule ExAtlas.Orchestrator.LeaseSigningTest do
  @moduledoc """
  A lease row carries a MAC over its owner and expiry (issue 148), under a
  key from the callback secret with a salt of its own.
  """

  use ExUnit.Case, async: false

  alias ExAtlas.Orchestrator.TrackingStore

  @secret "ex-atlas-test-callback-secret-0123456789"
  @at 1_790_000_000_000

  setup do
    Application.put_env(:ex_atlas, :callback, secret: @secret)
    on_exit(fn -> Application.delete_env(:ex_atlas, :callback) end)
  end

  test "a MAC this node wrote verifies for the same owner and expiry" do
    mac = TrackingStore.lease_mac("m1", @at)

    assert is_binary(mac)
    assert TrackingStore.lease_signed?("m1", @at, mac)
  end

  test "a MAC does not verify for another owner or expiry" do
    mac = TrackingStore.lease_mac("m1", @at)

    refute TrackingStore.lease_signed?("m5", @at, mac)
    refute TrackingStore.lease_signed?("m1", @at - 1, mac)
  end

  test "a MAC written under another secret does not verify" do
    Application.put_env(:ex_atlas, :callback, secret: String.duplicate("b", 40))
    mac = TrackingStore.lease_mac("m1", @at)
    Application.put_env(:ex_atlas, :callback, secret: @secret)

    refute TrackingStore.lease_signed?("m1", @at, mac)
  end

  test "no MAC, or one that is not a binary, does not verify" do
    for mac <- [nil, "", 42, String.to_charlist("x")] do
      refute TrackingStore.lease_signed?("m1", @at, mac)
    end
  end

  test "with no usable callback secret there is no MAC, and none verifies" do
    mac = TrackingStore.lease_mac("m1", @at)

    for config <- [[], [secret: "short"]] do
      Application.put_env(:ex_atlas, :callback, config)

      assert TrackingStore.lease_mac("m1", @at) == nil
      refute TrackingStore.lease_signed?("m1", @at, mac)
    end
  end

  # A lease MAC must never pass as a record's, nor a record's as a lease's:
  # the same bytes under the record key give another MAC.
  test "the lease key is not the record key" do
    record_key =
      Plug.Crypto.KeyGenerator.generate(@secret, "ex_atlas tracking record v1",
        cache: Plug.Crypto.Keys
      )

    bytes = :erlang.term_to_binary({"m1", @at}, [:deterministic])
    under_record_key = :crypto.mac(:hmac, :sha256, record_key, bytes)

    assert is_binary(TrackingStore.lease_mac("m1", @at))
    refute TrackingStore.lease_mac("m1", @at) == under_record_key
    refute TrackingStore.lease_signed?("m1", @at, under_record_key)
  end
end
