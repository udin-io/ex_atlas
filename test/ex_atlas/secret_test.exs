defmodule ExAtlas.SecretTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Secret

  doctest Secret

  @value "sk-secret-test-0f4d"

  test "no printer shows the value" do
    secret = Secret.wrap(@value)

    for text <- [
          inspect(secret),
          inspect(secret, structs: false),
          inspect(%{opts: [api_key: secret]}),
          :io_lib.format(~c"~p", [secret]) |> IO.iodata_to_binary()
        ] do
      refute text =~ @value
    end
  end

  test "interpolation raises instead of printing the value" do
    assert_raise Protocol.UndefinedError, fn -> "#{Secret.wrap(@value)}" end
  end

  test "reveal/1 returns what wrap/1 took" do
    assert Secret.reveal(Secret.wrap(@value)) == @value
    assert Secret.reveal(Secret.wrap({:bearer, @value})) == {:bearer, @value}
  end

  test "wrap/1 leaves nil and an existing Secret as they are" do
    assert Secret.wrap(nil) == nil
    secret = Secret.wrap(@value)
    assert Secret.wrap(secret) == secret
  end

  test "reveal/1 returns any other term unchanged" do
    assert Secret.reveal(nil) == nil
    assert Secret.reveal("plain") == "plain"
  end
end
