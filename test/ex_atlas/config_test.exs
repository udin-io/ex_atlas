defmodule ExAtlas.ConfigTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Config

  setup do
    original = Application.get_env(:ex_atlas, :default_provider)
    on_exit(fn -> Application.put_env(:ex_atlas, :default_provider, original) end)
    Application.delete_env(:ex_atlas, :default_provider)
    :ok
  end

  test "pop_provider! honors explicit :provider" do
    assert {:mock, [gpu: :h100]} = Config.pop_provider!(provider: :mock, gpu: :h100)
  end

  test "pop_provider! falls back to application env" do
    Application.put_env(:ex_atlas, :default_provider, :mock)
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
    Application.put_env(:ex_atlas, :runpod, api_key: "from-config")
    on_exit(fn -> Application.delete_env(:ex_atlas, :runpod) end)

    ctx = Config.build_ctx(:runpod, [])
    assert ctx.api_key == "from-config"
  end

  test "build_ctx threads provider-specific opts (e.g. :endpoint) into the ctx" do
    ctx = Config.build_ctx(:runpod, api_key: "k", endpoint: "abc123", job_endpoint: "def456")

    assert ctx.endpoint == "abc123"
    assert ctx.job_endpoint == "def456"
  end

  test "build_ctx keeps the resolved api_key, base_url and req_options authoritative" do
    ctx =
      Config.build_ctx(:runpod,
        api_key: "k",
        base_url: "http://example.test",
        req_options: [receive_timeout: 1],
        endpoint: "abc123"
      )

    assert ctx.api_key == "k"
    assert ctx.base_url == "http://example.test"
    assert ctx.req_options == [receive_timeout: 1]
    assert ctx.endpoint == "abc123"
  end

  test "provider_module maps atoms to modules" do
    assert Config.provider_module(:runpod) == ExAtlas.Providers.RunPod
    assert Config.provider_module(:mock) == ExAtlas.Providers.Mock
  end

  test "provider_module accepts user-supplied modules" do
    assert Config.provider_module(ExAtlas.Providers.Mock) == ExAtlas.Providers.Mock
  end

  test "provider_module raises on unknown" do
    assert_raise ArgumentError, ~r/unknown provider/, fn ->
      Config.provider_module(:does_not_exist)
    end
  end
end
