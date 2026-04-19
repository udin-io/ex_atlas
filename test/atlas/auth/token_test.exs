defmodule Atlas.Auth.TokenTest do
  use ExUnit.Case, async: true

  alias Atlas.Auth.Token

  test "mint/0 returns token + hash + header + env" do
    mint = Token.mint()
    assert byte_size(mint.token) >= 32
    assert mint.header == "Authorization: Bearer " <> mint.token
    assert mint.env == %{"ATLAS_PRESHARED_KEY" => mint.token}
    assert byte_size(mint.hash) == 64
  end

  test "valid?/2 accepts the minted token against its hash" do
    mint = Token.mint()
    assert Token.valid?(mint.token, mint.hash)
  end

  test "valid?/2 rejects other tokens" do
    mint = Token.mint()
    refute Token.valid?("not-the-token", mint.hash)
  end

  test "hash/1 is deterministic" do
    assert Token.hash("abc") == Token.hash("abc")
    refute Token.hash("abc") == Token.hash("abd")
  end
end
