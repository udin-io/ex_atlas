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
    assert ExAtlas.Secret.reveal(ctx.api_key) == "from-opts"
    assert ctx.provider == :runpod
  end

  test "build_ctx resolves api_key from app env" do
    Application.put_env(:ex_atlas, :runpod, api_key: "from-config")
    on_exit(fn -> Application.delete_env(:ex_atlas, :runpod) end)

    ctx = Config.build_ctx(:runpod, [])
    assert ExAtlas.Secret.reveal(ctx.api_key) == "from-config"
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

    assert ExAtlas.Secret.reveal(ctx.api_key) == "k"
    assert ctx.base_url == "http://example.test"
    assert ctx.req_options == [receive_timeout: 1]
    assert ctx.endpoint == "abc123"
  end

  describe "the provider's app config" do
    setup do
      on_exit(fn -> Application.delete_env(:ex_atlas, :runpod) end)
    end

    test "serves base_url to a call that passes none" do
      Application.put_env(:ex_atlas, :runpod, base_url: "https://proxy.internal/v1")

      assert Config.build_ctx(:runpod, api_key: "k").base_url == "https://proxy.internal/v1"
    end

    test "a per-call base_url wins over it" do
      Application.put_env(:ex_atlas, :runpod, base_url: "https://proxy.internal/v1")

      ctx = Config.build_ctx(:runpod, api_key: "k", base_url: "https://per-call.example")

      assert ctx.base_url == "https://per-call.example"
    end

    test "control: no base_url anywhere leaves the provider's own" do
      assert Config.build_ctx(:runpod, api_key: "k").base_url == nil
    end

    test "serves req_options, and per-call keys win over its keys" do
      Application.put_env(:ex_atlas, :runpod,
        req_options: [receive_timeout: 9_000, connect_options: [timeout: 1_000]]
      )

      ctx = Config.build_ctx(:runpod, api_key: "k", req_options: [receive_timeout: 5_000])

      assert Keyword.get(ctx.req_options, :receive_timeout) == 5_000
      assert Keyword.get(ctx.req_options, :connect_options) == [timeout: 1_000]
    end

    test "seals a credential in its req_options, as a per-call one is" do
      Application.put_env(:ex_atlas, :runpod,
        req_options: [headers: [{"x-proxy-key", "proxy-secret-7d1e"}]]
      )

      ctx = Config.build_ctx(:runpod, api_key: "k")

      assert %ExAtlas.Secret{} = Keyword.fetch!(ctx.req_options, :headers)
      refute inspect(ctx) =~ "proxy-secret-7d1e"
    end
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
