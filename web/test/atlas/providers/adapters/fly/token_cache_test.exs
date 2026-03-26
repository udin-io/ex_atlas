defmodule Atlas.Providers.Adapters.Fly.TokenCacheTest do
  use Atlas.DataCase, async: false

  alias Atlas.Providers.Adapters.Fly.TokenCache
  alias Atlas.Providers.Credential

  @test_token "fm2_test_token_abc123"
  # Nonexistent path so CliDetector.detect/1 won't find a config file
  @fake_config_path "/tmp/nonexistent_fly_config_#{System.unique_integer([:positive])}.yml"

  setup do
    # Unique names per test to avoid ETS table conflicts
    unique = System.unique_integer([:positive])
    server_name = :"token_cache_test_#{unique}"
    table_name = :"fly_tokens_test_#{unique}"

    # Clean up env var after each test
    original_env = System.get_env("FLY_ACCESS_TOKEN")

    on_exit(fn ->
      if original_env do
        System.put_env("FLY_ACCESS_TOKEN", original_env)
      else
        System.delete_env("FLY_ACCESS_TOKEN")
      end
    end)

    %{server_name: server_name, table_name: table_name}
  end

  defp start_cache(ctx) do
    start_supervised!(
      {TokenCache,
       name: ctx.server_name,
       table_name: ctx.table_name,
       cli_detector_opts: [config_path: @fake_config_path]}
    )

    :ok
  end

  describe "get_cli_token/1" do
    test "returns token from CliDetector on cache miss", ctx do
      System.put_env("FLY_ACCESS_TOKEN", @test_token)
      start_cache(ctx)

      assert {:ok, @test_token} = TokenCache.get_cli_token(ctx.server_name)
    end

    test "returns cached token on subsequent calls", ctx do
      System.put_env("FLY_ACCESS_TOKEN", @test_token)
      start_cache(ctx)

      # First call populates cache
      assert {:ok, @test_token} = TokenCache.get_cli_token(ctx.server_name)

      # Remove env var - should still return cached value
      System.delete_env("FLY_ACCESS_TOKEN")

      assert {:ok, @test_token} = TokenCache.get_cli_token(ctx.server_name)
    end

    test "returns :not_found when no sources available; nothing cached", ctx do
      System.delete_env("FLY_ACCESS_TOKEN")
      start_cache(ctx)

      assert :not_found = TokenCache.get_cli_token(ctx.server_name)

      # Verify nothing was cached
      assert :ets.lookup(ctx.table_name, :cli) == []
    end
  end

  describe "get_token/2" do
    test "fetches and caches credential token on miss", ctx do
      start_cache(ctx)

      {:ok, credential} =
        Credential.create(%{
          provider_type: :fly,
          name: "test-fly-cred",
          api_token: "fly_secret_token_xyz"
        })

      assert {:ok, "fly_secret_token_xyz"} = TokenCache.get_token(credential.id, ctx.server_name)

      # Verify it's in ETS
      cred_id = credential.id
      assert [{^cred_id, "fly_secret_token_xyz"}] = :ets.lookup(ctx.table_name, credential.id)
    end

    test "returns cached token on hit", ctx do
      start_cache(ctx)

      {:ok, credential} =
        Credential.create(%{
          provider_type: :fly,
          name: "test-fly-cred-2",
          api_token: "fly_secret_token_hit"
        })

      # First call
      assert {:ok, "fly_secret_token_hit"} = TokenCache.get_token(credential.id, ctx.server_name)

      # Second call should come from cache (even if credential were deleted, cache still has it)
      assert {:ok, "fly_secret_token_hit"} = TokenCache.get_token(credential.id, ctx.server_name)
    end

    test "returns error for nonexistent credential", ctx do
      start_cache(ctx)

      fake_id = Ash.UUID.generate()
      assert {:error, _} = TokenCache.get_token(fake_id, ctx.server_name)

      # Verify nothing was cached
      assert :ets.lookup(ctx.table_name, fake_id) == []
    end
  end

  describe "invalidate/2" do
    test "removes entry from ETS", ctx do
      System.put_env("FLY_ACCESS_TOKEN", @test_token)
      start_cache(ctx)

      # Populate cache
      assert {:ok, @test_token} = TokenCache.get_cli_token(ctx.server_name)
      assert :ets.lookup(ctx.table_name, :cli) != []

      # Invalidate
      :ok = TokenCache.invalidate(:cli, ctx.server_name)
      assert :ets.lookup(ctx.table_name, :cli) == []
    end

    test "is no-op for missing key", ctx do
      start_cache(ctx)

      # Should not raise
      assert :ok = TokenCache.invalidate(:nonexistent, ctx.server_name)
    end

    test "after invalidate(:cli), next get_cli_token re-fetches", ctx do
      System.put_env("FLY_ACCESS_TOKEN", @test_token)
      start_cache(ctx)

      assert {:ok, @test_token} = TokenCache.get_cli_token(ctx.server_name)

      # Invalidate and change token
      :ok = TokenCache.invalidate(:cli, ctx.server_name)
      new_token = "fm2_new_token_def456"
      System.put_env("FLY_ACCESS_TOKEN", new_token)

      assert {:ok, ^new_token} = TokenCache.get_cli_token(ctx.server_name)
    end
  end

  describe "concurrent access" do
    test "concurrent reads from multiple processes succeed", ctx do
      System.put_env("FLY_ACCESS_TOKEN", @test_token)
      start_cache(ctx)

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            TokenCache.get_cli_token(ctx.server_name)
          end)
        end

      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, &(&1 == {:ok, @test_token}))
    end
  end
end
