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

    test "prints no req_options :auth or :headers" do
      header_secret = "hdr-redaction-probe-8e2a"

      text =
        crash_text(fn ->
          ExAtlas.get_compute("pod-1",
            provider: ClauseProvider,
            req_options: [
              auth: {:bearer, @key},
              headers: [{"x-api-key", header_secret}],
              aws_sigv4: [access_key_id: "AKIDPROBE", secret_access_key: "sigv4-probe-61aa"]
            ]
          )
        end)

      assert text =~ "lookup(\"pod-1\""
      refute text =~ @key
      refute text =~ header_secret
      refute text =~ "sigv4-probe-61aa"
    end

    test "a req_options that is not a keyword list is refused by name, unprinted" do
      text =
        crash_text(fn ->
          ExAtlas.get_compute("pod-1",
            provider: ClauseProvider,
            req_options: %{auth: {:bearer, @key}}
          )
        end)

      assert text =~ "NimbleOptions.ValidationError"
      assert text =~ ":req_options"
      refute text =~ @key
    end

    test "control: the provider still receives the per-call key" do
      ExAtlas.get_compute("echo", provider: ClauseProvider, api_key: @key)

      assert_receive {:ctx, ctx}
      assert reveal(ctx.api_key) == @key
    end
  end

  describe "an api_key that is not a string" do
    test "is refused by name before any provider call, and never printed" do
      charlist = ~c"sk-charlist-probe-41b0"

      text =
        crash_text(fn -> ExAtlas.get_compute("pod-1", provider: :runpod, api_key: charlist) end)

      assert text =~ "NimbleOptions.ValidationError"
      assert text =~ ":api_key"
      refute text =~ "sk-charlist-probe-41b0"
    end

    test "is refused from application config too" do
      Application.put_env(:ex_atlas, ClauseProvider, api_key: ~c"sk-charlist-probe-41b0")

      text = crash_text(fn -> ExAtlas.get_compute("pod-1", provider: ClauseProvider) end)

      assert text =~ ":api_key"
      refute text =~ "sk-charlist-probe-41b0"
    end

    test "is an error from Orchestrator.spawn/1, before the provider is called" do
      ExAtlas.Test.Orchestrator.start!()

      assert {:error, %NimbleOptions.ValidationError{key: :api_key, value: nil} = error} =
               ExAtlas.Orchestrator.spawn(
                 provider: :mock,
                 gpu: :h100,
                 image: "x-api-key-invalid",
                 api_key: ~c"sk-charlist-probe-41b0"
               )

      refute inspect(error) =~ "sk-charlist-probe-41b0"
      refute Exception.message(error) =~ "sk-charlist-probe-41b0"
      {:ok, computes} = ExAtlas.list_compute(provider: :mock)
      refute Enum.any?(computes, &(&1.image == "x-api-key-invalid"))
    end
  end

  describe "the RunPod client" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
    end

    test "control: sends req_options :headers and :auth as given", %{
      bypass: bypass,
      base_url: base_url
    } do
      Bypass.expect_once(bypass, "GET", "/pods/pod-1", fn conn ->
        assert ["Bearer from-req-options"] = Plug.Conn.get_req_header(conn, "authorization")
        assert ["probe-value"] = Plug.Conn.get_req_header(conn, "x-probe")
        Plug.Conn.resp(conn, 404, "")
      end)

      ExAtlas.get_compute("pod-1",
        provider: :runpod,
        api_key: @key,
        base_url: base_url,
        req_options: [
          retry: false,
          auth: {:bearer, "from-req-options"},
          headers: [{"x-probe", "probe-value"}]
        ]
      )
    end
  end

  test "inspect/1 of a Compute prints no auth token" do
    compute = %ExAtlas.Spec.Compute{
      id: "pod-1",
      provider: :mock,
      status: :running,
      auth: %{
        scheme: :bearer,
        token: "tok-redaction-probe-c3f9",
        header: "Authorization",
        hash: nil
      }
    }

    text = inspect(compute)

    assert text =~ "pod-1"
    refute text =~ "tok-redaction-probe-c3f9"
  end
end
