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

  alias ExAtlas.{Error, Spec}
  alias ExAtlas.Providers.HTTP
  alias ExAtlas.Providers.Vast.{Client, Translate}

  @bundles "/api/v0/bundles/"

  @impl true
  def capabilities, do: [:raw_tcp]

  @impl true
  def spawn_compute(%Spec.ComputeRequest{} = request, ctx) do
    with :ok <- check_supported(request),
         {:ok, parts} <- Translate.launch_parts(request),
         body = Translate.launch_body(request, parts),
         {:ok, offers} <- offers(request, ctx),
         {:ok, id, offer} <- rent_first(ctx, offers, body) do
      {:ok, Translate.launched_compute(id, request, parts, offer)}
    end
  end

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
      {:ok, %{"success" => false} = body} -> {:error, refused(body, nil, "destroy")}
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

  # --- spawn ---

  defp check_supported(%Spec.ComputeRequest{} = request) do
    unsupported =
      [
        command: request.command not in [nil, []],
        spot: request.spot,
        template_id: request.template_id != nil,
        network_volume_id: request.network_volume_id != nil
      ]
      |> Enum.find(fn {_field, set?} -> set? end)

    case unsupported do
      nil -> :ok
      {field, _} -> unsupported("Vast does not take #{inspect(field)} in this ExAtlas release")
    end
  end

  defp offers(request, ctx) do
    case offer_id(request) do
      {:ok, id} ->
        {:ok, [%{"id" => id}]}

      :search ->
        searched_offers(request, ctx)

      {:error, _} = err ->
        err
    end
  end

  defp searched_offers(request, ctx) do
    with {:ok, query} <- Translate.offer_query(request),
         {:ok, found} <- search(ctx, query) do
      case Translate.pick(found, request.region_hints) do
        [] -> no_offer(request)
        picked -> {:ok, picked}
      end
    end
  end

  defp offer_id(request) do
    case Map.get(request.provider_opts, :offer_id) do
      nil ->
        :search

      id when is_integer(id) and id > 0 ->
        {:ok, id}

      _other ->
        {:error,
         Error.new(:validation,
           provider: :vast,
           message: "provider_opts.offer_id must be a positive integer"
         )}
    end
  end

  # A search rents nothing, so a transient failure is safe to retry.
  defp search(ctx, query) do
    case Client.post(ctx, @bundles, query, retry: :transient) do
      {:ok, %{"offers" => offers}} when is_list(offers) -> {:ok, offers}
      {:ok, _other} -> unexpected_body("POST #{@bundles}")
      {:error, _} = err -> err
    end
  end

  defp no_offer(request) do
    {:error,
     Error.new(:provider,
       provider: :vast,
       message:
         "Vast has no on-demand offer for #{request.gpu_count}x #{inspect(request.gpu)} " <>
           "with the disk and ports asked for"
     )}
  end

  # Tries each offer in turn. Only a refusal (a 4xx other than 401, 403 and
  # 429) moves on: it means Vast rented nothing, and offers are taken within
  # seconds. A 5xx or a timeout may have rented, so it stops the spawn.
  defp rent_first(ctx, [offer | rest], body) do
    case rent(ctx, offer, body) do
      {:ok, id} ->
        {:ok, id, if(Map.has_key?(offer, "dph_total"), do: offer)}

      {:error, error} ->
        if rest != [] and next_offer?(error),
          do: rent_first(ctx, rest, body),
          else: {:error, error}
    end
  end

  defp next_offer?(%Error{status: status}),
    do: is_integer(status) and status in 400..499 and status not in [401, 403, 429]

  # Retried on a 429 only: a rent that answered 5xx or timed out may have
  # rented an instance already.
  defp rent(ctx, %{"id" => offer_id}, body) do
    case Client.put(ctx, "/api/v0/asks/#{offer_id}/", body, retry: &HTTP.retry_rate_limited/2) do
      {:ok, %{"new_contract" => id}} when is_integer(id) ->
        {:ok, Integer.to_string(id)}

      {:ok, other} ->
        {:error, refused(other, 200, "rent")}

      {:error, %Error{status: status} = error} when is_integer(status) ->
        {:error, withhold(error)}

      {:error, _} = err ->
        err
    end
  end

  # Vast's `msg` can echo the request, `env` values included, as Lambda's
  # error text did (issue 84). An answered error keeps only Vast's `error`
  # code. A 401, 403 or 429 keeps its kind; a 404 names the offer, not an
  # instance, so it reads `:provider`.
  defp withhold(%Error{kind: kind} = error) do
    refused = refused(error.raw, error.status, "rent")

    if kind in [:unauthorized, :forbidden, :rate_limited],
      do: %{refused | kind: kind},
      else: refused
  end

  defp refused(body, status, action) do
    code = code(body)

    Error.new(:provider,
      provider: :vast,
      status: status,
      message:
        "Vast refused the #{action} (#{code || "no error code"}); ExAtlas withholds " <>
          "Vast's message, which can echo the request",
      raw: code && %{"error" => code}
    )
  end

  defp code(%{"error" => code}) when is_binary(code), do: code
  defp code(_body), do: nil

  # --- helpers ---

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
