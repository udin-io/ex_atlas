defmodule ExAtlas.Callback.TokenTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Callback.Token

  @secret String.duplicate("callback-test-secret", 4)

  describe "new_task_id/0" do
    test "mints a fresh, URL-safe id every time" do
      a = Token.new_task_id()
      b = Token.new_task_id()

      refute a == b
      assert a =~ ~r/\A[A-Za-z0-9_-]+\z/
      # 16 random bytes, unpadded base64url
      assert byte_size(a) == 22
    end
  end

  describe "mint/3 and verify/2" do
    test "a freshly minted token verifies back to its task and kinds" do
      token = Token.mint("task-1", [:progress, :finish], secret: @secret)

      assert {:ok, %{task_id: "task-1", kinds: [:progress, :finish]}} =
               Token.verify(token, secret: @secret)
    end

    test "the token is opaque — the task id is not readable from it" do
      token = Token.mint("super-secret-task", [:progress], secret: @secret)

      refute token =~ "super-secret-task"
    end

    test "a token signed with another secret does not verify" do
      token = Token.mint("task-1", [:progress], secret: @secret)

      assert {:error, :invalid} =
               Token.verify(token, secret: String.duplicate("a-different-secret", 4))
    end

    test "a tampered token does not verify" do
      token = Token.mint("task-1", [:progress], secret: @secret)
      forged = String.replace(token, ~r/.\z/, "X")

      assert {:error, :invalid} = Token.verify(forged, secret: @secret)
    end

    test "garbage does not verify" do
      assert {:error, :invalid} = Token.verify("not-a-token", secret: @secret)
      assert {:error, :invalid} = Token.verify("", secret: @secret)
    end

    test "a token past its max age is expired, not merely invalid" do
      an_hour_ago = System.os_time(:second) - 3_600

      token =
        Token.mint("task-1", [:progress], secret: @secret, max_age: 60, signed_at: an_hour_ago)

      assert {:error, :expired} = Token.verify(token, secret: @secret)
    end

    test "the max age travels inside the token, so verification needs no per-task state" do
      a_minute_ago = System.os_time(:second) - 60

      short = Token.mint("t", [:progress], secret: @secret, max_age: 1, signed_at: a_minute_ago)

      long =
        Token.mint("t", [:progress], secret: @secret, max_age: 86_400, signed_at: a_minute_ago)

      assert {:error, :expired} = Token.verify(short, secret: @secret)
      assert {:ok, _} = Token.verify(long, secret: @secret)
    end

    test "permits/2 gates the kinds the token was minted for" do
      {:ok, claims} = Token.verify(Token.mint("t", [:progress], secret: @secret), secret: @secret)

      assert Token.permits?(claims, :progress)
      refute Token.permits?(claims, :log)
      refute Token.permits?(claims, :finish)
    end
  end

  describe "secret resolution" do
    test "raises a directive error when no callback secret is configured" do
      assert_raise ArgumentError, ~r/callback secret/, fn ->
        Token.mint("t", [:progress], secret: nil)
      end
    end

    test "refuses a secret too short to key an HMAC" do
      assert_raise ArgumentError, ~r/at least 32 bytes/, fn ->
        Token.mint("t", [:progress], secret: "short")
      end
    end
  end
end
