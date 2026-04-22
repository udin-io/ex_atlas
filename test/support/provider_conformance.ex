defmodule ExAtlas.Test.ProviderConformance do
  @moduledoc """
  Shared ExUnit suite every `ExAtlas.Provider` implementation must pass.

  Usage:

      defmodule ExAtlas.Providers.MockTest do
        use ExUnit.Case, async: false
        use ExAtlas.Test.ProviderConformance,
          provider: :mock,
          reset: {ExAtlas.Providers.Mock, :reset, []}
      end

  The `:reset` option names a `{mod, fun, args}` tuple the suite calls in its
  `setup` block. Real providers pass a no-op or a Bypass-based helper.
  """

  @doc false
  def build_reset_call(nil), do: quote(do: :ok)

  # `use ExAtlas.Test.ProviderConformance, reset: {ExAtlas.Providers.Mock, :reset, []}`
  # passes the 3-tuple as a quoted AST (`{:{}, meta, [mod_alias, fun, args]}`).
  # We rebuild it as an `apply/3` call — unquoting the AST nodes directly so the
  # alias resolves at the call site.
  def build_reset_call({:{}, _, [mod, fun, args]}) do
    quote do
      apply(unquote(mod), unquote(fun), unquote(args))
    end
  end

  def build_reset_call({mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args) do
    quote do
      apply(unquote(mod), unquote(fun), unquote(args))
    end
  end

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)
    reset_call = build_reset_call(Keyword.get(opts, :reset))

    quote do
      alias ExAtlas.Spec

      @provider unquote(provider)

      setup do
        unquote(reset_call)
        :ok
      end

      test "capabilities/0 returns a list of atoms" do
        caps = ExAtlas.capabilities(@provider)
        assert is_list(caps)
        assert Enum.all?(caps, &is_atom/1)
      end

      test "spawn_compute → get_compute → terminate round-trip" do
        {:ok, compute} =
          ExAtlas.spawn_compute(
            provider: @provider,
            gpu: :h100,
            image: "test/image:latest",
            ports: [{8000, :http}]
          )

        assert %Spec.Compute{provider: @provider} = compute
        assert is_binary(compute.id)

        {:ok, fetched} = ExAtlas.get_compute(compute.id, provider: @provider)
        assert fetched.id == compute.id

        :ok = ExAtlas.terminate(compute.id, provider: @provider)
      end

      test "spawn_compute with auth: :bearer returns a token" do
        {:ok, compute} =
          ExAtlas.spawn_compute(
            provider: @provider,
            gpu: :h100,
            image: "test/image",
            auth: :bearer
          )

        assert %{scheme: :bearer, token: token, hash: hash} = compute.auth
        assert is_binary(token) and byte_size(token) >= 32
        assert is_binary(hash)
      end

      test "list_compute returns a list" do
        {:ok, _} = ExAtlas.spawn_compute(provider: @provider, gpu: :h100, image: "test/image")
        {:ok, all} = ExAtlas.list_compute(provider: @provider)
        assert is_list(all)
      end
    end
  end
end
