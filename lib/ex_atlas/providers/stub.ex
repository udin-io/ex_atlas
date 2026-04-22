defmodule ExAtlas.Providers.Stub do
  @moduledoc """
  Shared base for placeholder providers that haven't been implemented yet.

  Future `ExAtlas.Providers.Fly`, `ExAtlas.Providers.LambdaLabs`, `ExAtlas.Providers.Vast`
  modules `use` this to reserve the provider atom in `ExAtlas.Config`, expose an
  accurate `capabilities/0` list, and fail every other callback with a clear
  `{:error, :not_implemented}` so callers get a helpful message rather than a
  `FunctionClauseError`.

  When a real implementation lands, the provider module stops `use`-ing `Stub`
  and implements the callbacks directly — no downstream call-site changes.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)
    caps = Keyword.get(opts, :capabilities, [])
    docs_url = Keyword.get(opts, :docs_url)

    quote bind_quoted: [provider: provider, caps: caps, docs_url: docs_url] do
      @behaviour ExAtlas.Provider

      @provider_atom provider
      @provider_caps caps
      @docs_url docs_url

      @impl true
      def capabilities, do: @provider_caps

      @impl true
      def spawn_compute(_request, _ctx), do: not_implemented(:spawn_compute)

      @impl true
      def get_compute(_id, _ctx), do: not_implemented(:get_compute)

      @impl true
      def list_compute(_filters, _ctx), do: not_implemented(:list_compute)

      @impl true
      def stop(_id, _ctx), do: not_implemented(:stop)

      @impl true
      def start(_id, _ctx), do: not_implemented(:start)

      @impl true
      def terminate(_id, _ctx), do: not_implemented(:terminate)

      @impl true
      def run_job(_req, _ctx), do: not_implemented(:run_job)

      @impl true
      def get_job(_id, _ctx), do: not_implemented(:get_job)

      @impl true
      def cancel_job(_id, _ctx), do: not_implemented(:cancel_job)

      @impl true
      def stream_job(_id, _ctx),
        do: Stream.map([{:error, ExAtlas.Error.new(:unsupported, provider: @provider_atom)}], & &1)

      @impl true
      def list_gpu_types(_ctx), do: not_implemented(:list_gpu_types)

      defp not_implemented(fun) do
        msg =
          "ExAtlas provider #{inspect(@provider_atom)}.#{fun}/_ is not implemented yet." <>
            if(@docs_url, do: " See #{@docs_url} for status.", else: "")

        {:error, ExAtlas.Error.new(:unsupported, provider: @provider_atom, message: msg)}
      end
    end
  end
end
