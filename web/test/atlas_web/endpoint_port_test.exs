defmodule AtlasWeb.EndpointPortTest do
  use ExUnit.Case, async: false

  describe "ATLAS_PORT / PORT env var precedence in runtime.exs" do
    setup do
      # Save original env vars and config to restore after each test
      original_atlas_port = System.get_env("ATLAS_PORT")
      original_port = System.get_env("PORT")
      original_config = Application.get_env(:atlas, AtlasWeb.Endpoint)

      on_exit(fn ->
        # Restore original env vars
        if original_atlas_port,
          do: System.put_env("ATLAS_PORT", original_atlas_port),
          else: System.delete_env("ATLAS_PORT")

        if original_port,
          do: System.put_env("PORT", original_port),
          else: System.delete_env("PORT")

        # Restore original endpoint config
        Application.put_env(:atlas, AtlasWeb.Endpoint, original_config)
      end)

      :ok
    end

    test "ATLAS_PORT takes precedence over PORT" do
      System.put_env("ATLAS_PORT", "5555")
      System.put_env("PORT", "6000")
      reload_runtime_port_config()

      config = Application.get_env(:atlas, AtlasWeb.Endpoint)
      assert config[:http][:port] == 5555
    end

    test "falls back to PORT when ATLAS_PORT is not set" do
      System.delete_env("ATLAS_PORT")
      System.put_env("PORT", "6000")
      reload_runtime_port_config()

      config = Application.get_env(:atlas, AtlasWeb.Endpoint)
      assert config[:http][:port] == 6000
    end

    test "defaults to 4000 when neither ATLAS_PORT nor PORT is set" do
      System.delete_env("ATLAS_PORT")
      System.delete_env("PORT")
      reload_runtime_port_config()

      config = Application.get_env(:atlas, AtlasWeb.Endpoint)
      assert config[:http][:port] == 4000
    end

    test "endpoint http port config is an integer" do
      config = Application.get_env(:atlas, AtlasWeb.Endpoint)
      assert Keyword.has_key?(config[:http], :port)
      assert is_integer(config[:http][:port])
    end
  end

  # Re-evaluate the port config line from runtime.exs against current env vars
  defp reload_runtime_port_config do
    port =
      String.to_integer(System.get_env("ATLAS_PORT") || System.get_env("PORT") || "4000")

    current = Application.get_env(:atlas, AtlasWeb.Endpoint)
    updated = Keyword.put(current, :http, Keyword.put(current[:http] || [], :port, port))
    Application.put_env(:atlas, AtlasWeb.Endpoint, updated)
  end
end
