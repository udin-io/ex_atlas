defmodule ExAtlas.Providers.Vast do
  @moduledoc """
  `ExAtlas.Provider` implementation for [Vast.ai](https://vast.ai) on-demand
  instances.

  Vast is a marketplace: a spawn searches the on-demand offers that match
  `:gpu`, `:gpu_count`, `:container_disk_gb` (default 20 GB) and the number
  of `:ports`, and rents the cheapest. It runs `:image` with its own
  entrypoint and passes `:env`, `:s3`, `:auth` and `:ports`.

      config :ex_atlas, :vast, api_key: System.get_env("VAST_API_KEY")

      {:ok, compute} =
        ExAtlas.spawn_compute(
          provider: :vast,
          gpu: :rtx_4090,
          image: "vllm/vllm-openai:latest",
          ports: [{8000, :http}],
          region_hints: ["US"],
          auth: :bearer
        )

  `:region_hints` are country codes: the spawn rents in the first hinted
  country that has an offer, else the cheapest anywhere. `cloud_type: :secure`
  rents datacenter hosts only. `provider_opts: %{offer_id: id}` rents that
  offer, with no search.

  A refused rent (a 4xx) tries the next of the three cheapest offers. A rent
  answered 5xx or not at all may have rented, so it returns its error and
  tries nothing else.

  Each container port maps to a random host port, so a port's URL is
  `http://<public ip>:<host port>`. The URL is `nil` until Vast reports the
  mapping.

  Not yet on Vast: `:command`, `spot: true`, `:template_id` and
  `:network_volume_id` are `:unsupported`, and so are `stop/2` and `start/2`.
  """

  @behaviour ExAtlas.Provider

  alias ExAtlas.Error
  alias ExAtlas.Providers.Vast.{Client, Translate}

  @impl true
  def capabilities, do: [:raw_tcp]

  @impl true
  def spawn_compute(_request, _ctx), do: unsupported("Vast spawn_compute/2 is not built yet")

  @impl true
  def get_compute(id, ctx) do
    case Client.get(ctx, "/api/v0/instances/#{encode(id)}/") do
      {:ok, %{"instances" => %{} = instance}} -> {:ok, Translate.instance_to_compute(instance)}
      # vast-cli reads `instances: null` as an instance that does not exist.
      {:ok, %{"instances" => nil}} -> not_found(id)
      {:ok, _other} -> unexpected_body("GET /api/v0/instances/#{id}/")
      {:error, _} = err -> err
    end
  end

  @impl true
  # Status and GPU filters need the translated `Compute`, so every filter
  # applies here.
  def list_compute(filters, ctx) do
    with {:ok, instances} <- Client.list_instances(ctx) do
      {:ok,
       instances
       |> Enum.map(&Translate.instance_to_compute/1)
       |> Enum.filter(&matches_filters?(&1, filters))}
    end
  end

  @impl true
  def terminate(id, ctx) do
    case Client.delete(ctx, "/api/v0/instances/#{encode(id)}/") do
      {:ok, %{"success" => false} = body} -> {:error, refused(body)}
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def stop(_id, _ctx), do: unsupported("Vast stop/2 is not in this ExAtlas release")

  @impl true
  def start(_id, _ctx), do: unsupported("Vast start/2 is not in this ExAtlas release")

  @impl true
  def list_gpu_types(_ctx), do: unsupported("Vast list_gpu_types/1 is not built yet")

  # --- helpers ---

  # Vast's `msg` can echo a request; a refusal keeps only Vast's `error` code.
  defp refused(body) do
    code = code(body)

    Error.new(:provider,
      provider: :vast,
      message: "Vast refused the destroy (#{code || "no error code"})",
      raw: code && %{"error" => code}
    )
  end

  defp code(%{"error" => code}) when is_binary(code), do: code
  defp code(_body), do: nil

  defp encode(id), do: URI.encode(to_string(id), &URI.char_unreserved?/1)

  defp not_found(id) do
    {:error, Error.new(:not_found, provider: :vast, message: "Vast has no instance #{id}")}
  end

  defp unsupported(message),
    do: {:error, Error.new(:unsupported, provider: :vast, message: message)}

  defp unexpected_body(call) do
    {:error, Error.new(:provider, provider: :vast, message: "unexpected body for #{call}")}
  end

  defp matches_filters?(compute, filters) do
    Enum.all?(filters, fn
      {:status, s} -> compute.status == s
      {:name, n} -> compute.name == n
      {:region, r} -> compute.region == r
      {:gpu, g} -> Translate.gpu_family?(compute.gpu_type, g)
      _ -> true
    end)
  end
end
