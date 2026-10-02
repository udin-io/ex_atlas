defmodule ExAtlas.CredentialRedactionTest do
  # A provider bug or a bad input must not print the caller's credentials. The
  # BEAM puts a crashed function's arguments in the stacktrace, and every
  # provider call takes the ctx, so the ctx must print no credential.
  use ExUnit.Case, async: false

  @key "sk-redaction-probe-5d1c"

  # Delegates to the Mock, except `get_compute/2`, which crashes with a
  # FunctionClauseError on any id but "known", and echoes the ctx on "echo".
  defmodule ClauseProvider do
    @moduledoc false
    alias ExAtlas.Providers.Mock

    def capabilities, do: Mock.capabilities()
    defdelegate spawn_compute(req, ctx), to: Mock
    defdelegate terminate(id, ctx), to: Mock

    def get_compute("echo", ctx) do
      send(self(), {:ctx, ctx})
      {:error, :echoed}
    end

    def get_compute(id, ctx), do: lookup(id, ctx)

    defp lookup("known", _ctx), do: {:error, :not_found}
  end

  setup do
    original = Application.get_env(:ex_atlas, ClauseProvider)
    on_exit(fn -> restore_env(ClauseProvider, original) end)
    Application.delete_env(:ex_atlas, ClauseProvider)
    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:ex_atlas, key)
  defp restore_env(key, value), do: Application.put_env(:ex_atlas, key, value)

  # What a crash report prints: the banner, then the stacktrace with the top
  # frame's arguments.
  defp crash_text(fun) do
    fun.()
    flunk("expected a crash")
  rescue
    error -> Exception.format(:error, error, __STACKTRACE__)
  end

  defp reveal(%{__struct__: _} = secret), do: ExAtlas.Secret.reveal(secret)
  defp reveal(value), do: value

  describe "a provider crash" do
    test "prints no per-call api_key" do
      text =
        crash_text(fn ->
          ExAtlas.get_compute("pod-1", provider: ClauseProvider, api_key: @key)
        end)

      # The stacktrace printed the ctx, so the refute is not vacuous.
      assert text =~ "FunctionClauseError"
      assert text =~ "lookup(\"pod-1\""
      assert text =~ "provider: ExAtlas.CredentialRedactionTest.ClauseProvider"
      refute text =~ @key
    end

    test "prints no api_key resolved from application config" do
      Application.put_env(:ex_atlas, ClauseProvider, api_key: @key)

      text = crash_text(fn -> ExAtlas.get_compute("pod-1", provider: ClauseProvider) end)

      assert text =~ "lookup(\"pod-1\""
      refute text =~ @key
    end

    test "control: the provider still receives the per-call key" do
      ExAtlas.get_compute("echo", provider: ClauseProvider, api_key: @key)

      assert_receive {:ctx, ctx}
      assert reveal(ctx.api_key) == @key
    end
  end
end
