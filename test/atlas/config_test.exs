defmodule Atlas.ConfigTest do
  use ExUnit.Case, async: false

  alias Atlas.Config

  setup do
    original = Application.get_env(:atlas, :default_provider)
    on_exit(fn -> Application.put_env(:atlas, :default_provider, original) end)
    Application.delete_env(:atlas, :default_provider)
    :ok
  end

  test "pop_provider! honors explicit :provider" do
    assert {:mock, [gpu: :h100]} = Config.pop_provider!(provider: :mock, gpu: :h100)
  end

  test "pop_provider! falls back to application env" do
    Application.put_env(:atlas, :default_provider, :mock)
    assert {:mock, [gpu: :h100]} = Config.pop_provider!(gpu: :h100)
  end

  test "pop_provider! raises with helpful message when unset" do
    assert_raise ArgumentError, ~r/default_provider/, fn ->
      Config.pop_provider!(gpu: :h100)
    end
  end

  test "build_ctx resolves api_key from opts" do
    ctx = Config.build_ctx(:runpod, api_key: "from-opts")
    assert ctx.api_key == "from-opts"
    assert ctx.provider == :runpod
  end

  test "build_ctx resolves api_key from app env" do
    Application.put_env(:atlas, :runpod, api_key: "from-config")
    on_exit(fn -> Application.delete_env(:atlas, :runpod) end)

    ctx = Config.build_ctx(:runpod, [])
    assert ctx.api_key == "from-config"
  end

  test "provider_module maps atoms to modules" do
    assert Config.provider_module(:runpod) == Atlas.Providers.RunPod
    assert Config.provider_module(:mock) == Atlas.Providers.Mock
  end

  test "provider_module accepts user-supplied modules" do
    assert Config.provider_module(Atlas.Providers.Mock) == Atlas.Providers.Mock
  end

  test "provider_module raises on unknown" do
    assert_raise ArgumentError, ~r/unknown provider/, fn ->
      Config.provider_module(:does_not_exist)
    end
  end
end
