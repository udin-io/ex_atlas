defmodule AtlasWeb.EndpointPortTest do
  use ExUnit.Case, async: true

  describe "ATLAS_PORT / PORT env var precedence in runtime.exs" do
    test "ATLAS_PORT takes precedence over PORT" do
      # Simulate the same logic used in runtime.exs
      result = fn atlas_port, port ->
        String.to_integer(atlas_port || port || "4000")
      end

      # ATLAS_PORT set, PORT set — ATLAS_PORT wins
      assert result.("5555", "6000") == 5555

      # Only ATLAS_PORT set
      assert result.("5555", nil) == 5555

      # Only PORT set
      assert result.(nil, "6000") == 6000

      # Neither set — default 4000
      assert result.(nil, nil) == 4000
    end

    test "endpoint http port config is set" do
      # Verify the endpoint config has an http port configured
      config = Application.get_env(:atlas, AtlasWeb.Endpoint)
      assert Keyword.has_key?(config[:http], :port)
      assert is_integer(config[:http][:port])
    end
  end
end
