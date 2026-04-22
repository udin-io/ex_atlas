defmodule ExAtlas.Fly.TokenStorageConformance do
  @moduledoc """
  Shared ExUnit suite every `ExAtlas.Fly.TokenStorage` implementation must pass.

  Covers the `get/2` / `put/3` / `delete/2` contract across both `:cached` and
  `:manual` keys, plus nil-`expires_at` handling for manual tokens. Any future
  adapter (Redis, Postgres, vault-backed) can `use` this suite to inherit
  parity tests for free.

  ## Usage

      defmodule ExAtlas.Fly.TokenStorage.MemoryTest do
        use ExUnit.Case, async: false

        use ExAtlas.Fly.TokenStorageConformance,
          storage: ExAtlas.Fly.TokenStorage.Memory,
          setup: {__MODULE__, :start, []}
      end

  ### Options

    * `:storage` (required) — the module implementing
      `ExAtlas.Fly.TokenStorage`.
    * `:setup` — `{mod, fun, args}` called from the suite's `setup` block.
      Use it to `start_supervised!/1` the impl and perform any test isolation
      (e.g. wiping a DETS file). Defaults to a no-op.
  """

  @doc false
  def build_setup_call(nil), do: quote(do: :ok)

  def build_setup_call({:{}, _, [mod, fun, args]}) do
    quote do: apply(unquote(mod), unquote(fun), unquote(args))
  end

  def build_setup_call({mod, fun, args})
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    quote do: apply(unquote(mod), unquote(fun), unquote(args))
  end

  defmacro __using__(opts) do
    storage = Keyword.fetch!(opts, :storage)
    setup_call = build_setup_call(Keyword.get(opts, :setup))

    quote do
      @storage unquote(storage)

      setup do
        unquote(setup_call)
        :ok
      end

      describe "conformance: cached key" do
        test "get/2 on empty storage returns :error" do
          assert :error = @storage.get("absent-app", :cached)
        end

        test "put/3 then get/2 round-trips token and expires_at" do
          expires_at = System.system_time(:second) + 3_600
          :ok = @storage.put("app-a", :cached, %{token: "t-a", expires_at: expires_at})

          assert {:ok, %{token: "t-a", expires_at: ^expires_at}} = @storage.get("app-a", :cached)
        end

        test "put/3 overwrites an existing entry" do
          :ok = @storage.put("app-b", :cached, %{token: "old", expires_at: 1})
          :ok = @storage.put("app-b", :cached, %{token: "new", expires_at: 2})

          assert {:ok, %{token: "new", expires_at: 2}} = @storage.get("app-b", :cached)
        end

        test "delete/2 removes the entry" do
          :ok = @storage.put("app-c", :cached, %{token: "t", expires_at: 1})
          :ok = @storage.delete("app-c", :cached)

          assert :error = @storage.get("app-c", :cached)
        end

        test "delete/2 is a no-op on absent entries" do
          assert :ok = @storage.delete("never-existed", :cached)
        end
      end

      describe "conformance: manual key" do
        test "put/3 accepts nil expires_at and round-trips it" do
          :ok = @storage.put("app-m", :manual, %{token: "mtok", expires_at: nil})

          assert {:ok, %{token: "mtok", expires_at: nil}} = @storage.get("app-m", :manual)
        end

        test ":cached and :manual entries are independent for the same app" do
          :ok = @storage.put("shared-app", :cached, %{token: "c-tok", expires_at: 100})
          :ok = @storage.put("shared-app", :manual, %{token: "m-tok", expires_at: nil})

          assert {:ok, %{token: "c-tok"}} = @storage.get("shared-app", :cached)
          assert {:ok, %{token: "m-tok"}} = @storage.get("shared-app", :manual)

          :ok = @storage.delete("shared-app", :cached)

          assert :error = @storage.get("shared-app", :cached)
          assert {:ok, %{token: "m-tok"}} = @storage.get("shared-app", :manual)
        end
      end
    end
  end
end
