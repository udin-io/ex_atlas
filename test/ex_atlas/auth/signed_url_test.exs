defmodule ExAtlas.Auth.SignedUrlTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Auth.SignedUrl

  @secret "test-secret-test-secret-test-secret"

  test "sign + verify round-trip succeeds" do
    signed = SignedUrl.sign("https://x.test/stream/42", secret: @secret, expires_in: 60)
    assert :ok == SignedUrl.verify(signed, secret: @secret)
  end

  test "verify rejects tampered signature" do
    signed =
      "https://x.test/stream/42"
      |> SignedUrl.sign(secret: @secret, expires_in: 60)
      |> String.replace(~r/sig=[^&]+/, "sig=tampered")

    assert {:error, :bad_signature} = SignedUrl.verify(signed, secret: @secret)
  end

  test "verify rejects wrong secret" do
    signed = SignedUrl.sign("https://x.test/a", secret: @secret, expires_in: 60)
    assert {:error, :bad_signature} = SignedUrl.verify(signed, secret: "other")
  end

  test "verify rejects expired URL" do
    now = System.system_time(:second)
    signed = SignedUrl.sign("https://x.test/a", secret: @secret, expires_in: 10, now: now - 100)
    assert {:error, :expired} = SignedUrl.verify(signed, secret: @secret)
  end

  test "preserves existing query parameters" do
    signed =
      SignedUrl.sign("https://x.test/a?user=42", secret: @secret, expires_in: 60)

    assert signed =~ "user=42"
    assert :ok == SignedUrl.verify(signed, secret: @secret)
  end
end
