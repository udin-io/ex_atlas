defmodule Atlas.Providers.Adapters.Fly.CliDetectorTest do
  use ExUnit.Case, async: false

  alias Atlas.Providers.Adapters.Fly.CliDetector

  @fixtures_path Path.expand("../../../../fixtures/fly", __DIR__)
  @valid_config Path.join(@fixtures_path, "valid_config.yml")
  @malformed_config Path.join(@fixtures_path, "malformed_config.yml")
  @missing_token_config Path.join(@fixtures_path, "missing_token_config.yml")

  setup do
    on_exit(fn ->
      System.delete_env("FLY_ACCESS_TOKEN")
    end)

    System.delete_env("FLY_ACCESS_TOKEN")
    :ok
  end

  describe "detect/1" do
    test "detects token from FLY_ACCESS_TOKEN env var" do
      System.put_env("FLY_ACCESS_TOKEN", "token-123")

      assert {:ok, "token-123"} = CliDetector.detect(config_path: "/nonexistent")
    end

    test "env var takes priority over config file" do
      System.put_env("FLY_ACCESS_TOKEN", "env-token")

      assert {:ok, "env-token"} = CliDetector.detect(config_path: @valid_config)
    end

    test "detects token from config file when env var is not set" do
      assert {:ok, "test-token-abc123"} = CliDetector.detect(config_path: @valid_config)
    end

    test "returns :not_found when no sources available" do
      assert :not_found = CliDetector.detect(config_path: "/nonexistent/config.yml")
    end

    test "returns :not_found for malformed YAML config" do
      assert :not_found = CliDetector.detect(config_path: @malformed_config)
    end

    test "returns :not_found when access_token key is missing from config" do
      assert :not_found = CliDetector.detect(config_path: @missing_token_config)
    end

    test "trims whitespace from env var token" do
      System.put_env("FLY_ACCESS_TOKEN", "  tok  ")

      assert {:ok, "tok"} = CliDetector.detect(config_path: "/nonexistent")
    end

    test "returns :not_found for empty env var" do
      System.put_env("FLY_ACCESS_TOKEN", "")

      assert :not_found = CliDetector.detect(config_path: "/nonexistent/config.yml")
    end
  end
end
