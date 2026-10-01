defmodule ExAtlas.Fly.Tokens.AppServerTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Fly.Tokens.AppServer

  describe "parse_access_token/1 (the ~/.fly/config.yml reader)" do
    test "returns a quoted access_token with its quotes removed" do
      assert {:ok, "FlyV1 fm2_quoted"} =
               AppServer.parse_access_token("access_token: \"FlyV1 fm2_quoted\"\n")
    end

    test "returns an unquoted access_token among other keys" do
      assert {:ok, "FlyV1 fm2_plain"} =
               AppServer.parse_access_token("other: 1\naccess_token: FlyV1 fm2_plain\n")
    end

    test "an empty access_token is a miss" do
      assert :miss = AppServer.parse_access_token("access_token: \"\"\n")
    end

    test "a file without an access_token key is a miss" do
      assert :miss = AppServer.parse_access_token("other: 1\n")
    end
  end
end
