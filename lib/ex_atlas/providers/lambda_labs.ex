defmodule ExAtlas.Providers.LambdaLabs do
  @moduledoc """
  `ExAtlas.Provider` implementation for [Lambda Cloud](https://lambda.ai)
  on-demand instances, through its Cloud API v1.

  Lambda rents VMs, not containers. A spawn with an `:image` hands the VM a
  cloud-init script that starts the image with `docker run`, passing `:env`,
  `:s3`, `:auth` and `:ports`. See `ExAtlas.Providers.LambdaLabs.Translate`.

      config :ex_atlas, :lambda_labs,
        api_key: System.get_env("LAMBDA_LABS_API_KEY"),
        ssh_key_name: "deploy"

      {:ok, compute} =
        ExAtlas.spawn_compute(
          provider: :lambda_labs,
          gpu: :h100,
          image: "vllm/vllm-openai:latest",
          ports: [{8000, :http}],
          auth: :bearer
        )

  Lambda requires exactly one SSH key: `provider_opts: %{ssh_key_name: name}`,
  else the `:ssh_key_name` app config. `provider_opts: %{instance_type: name}`
  launches that type instead of the one `:gpu` and `:gpu_count` name.

  The spawn picks the first of `:region_hints` with capacity, else Lambda's
  first region with capacity. Lambda has no stop, no spot, no templates and no
  network volumes: those return `:unsupported`. Open the `:ports` in Lambda's
  firewall yourself, in the Lambda dashboard.

  `:command` runs in the container. An instance cannot delete itself, so the
  default `self_terminate: true` needs a `:callback`: the host POSTs the
  container's exit code to it, and `ExAtlas.Orchestrator.run_task/1`'s
  tracker deletes the instance on that report. Without a callback, pass
  `self_terminate: false`; `:validation` otherwise.
  """

  @behaviour ExAtlas.Provider

  alias ExAtlas.{Error, Spec}
  alias ExAtlas.Providers.HTTP
  alias ExAtlas.Providers.LambdaLabs.{Client, Translate}

  @impl true
  def capabilities, do: [:raw_tcp]

  @impl true
  def spawn_compute(%Spec.ComputeRequest{} = request, ctx) do
    with :ok <- check_supported(request),
         {:ok, ssh_key} <- ssh_key(request),
         {:ok, parts} <- Translate.launch_parts(request, DateTime.utc_now()),
         {:ok, types} <- instance_types(ctx),
         {:ok, type} <- Translate.instance_type(request, types),
         {:ok, region} <- Translate.region(type, types[type], request.region_hints),
         body = Translate.launch_body(request, parts, type, region, ssh_key),
         {:ok, id} <- launch(ctx, body) do
      {:ok, Translate.launched_compute(id, request, parts, types[type], region)}
    end
  end

  @impl true
  def get_compute(id, ctx) do
    case Client.get(ctx, "/instances/#{URI.encode(id, &URI.char_unreserved?/1)}") do
      {:ok, %{} = instance} -> {:ok, Translate.instance_to_compute(instance)}
      {:ok, _other} -> unexpected_body("GET /instances/#{id}")
      {:error, _} = err -> err
    end
  end

  @impl true
  # Lambda filters nothing server-side, so every filter applies here, to the
  # translated `Compute`.
  def list_compute(filters, ctx) do
    with {:ok, instances} <- Client.list_all(ctx, "/instances") do
      {:ok,
       instances
       |> Enum.map(&Translate.instance_to_compute/1)
       |> Enum.filter(&matches_filters?(&1, filters))}
    end
  end

  @impl true
  def terminate(id, ctx) do
    case Client.post(ctx, "/instance-operations/terminate", %{"instance_ids" => [id]}) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def stop(_id, _ctx), do: no_stop(:stop)

  @impl true
  def start(_id, _ctx), do: no_stop(:start)

  @impl true
  def list_gpu_types(ctx) do
    with {:ok, types} <- instance_types(ctx), do: {:ok, Translate.gpu_types(types)}
  end

  # --- spawn ---

  defp check_supported(%Spec.ComputeRequest{} = request) do
    unsupported =
      [
        spot: request.spot,
        template_id: request.template_id != nil,
        network_volume_id: request.network_volume_id != nil
      ]
      |> Enum.find(fn {_field, set?} -> set? end)

    case unsupported do
      nil -> check_self_terminate(request)
      {field, _} -> unsupported("Lambda has no #{field}")
    end
  end

  # `self_terminate` defaults on to stop a bill. Lambda gives an instance no
  # key to delete itself, so only a callback report, which the tracker turns
  # into a terminate, can end the instance when its command exits.
  defp check_self_terminate(%Spec.ComputeRequest{command: [_ | _], self_terminate: true} = r)
       when is_nil(r.callback) do
    {:error,
     Error.new(:validation,
       provider: :lambda_labs,
       message:
         "Lambda cannot delete an instance from inside it: pass self_terminate: false, " <>
           "or run it through ExAtlas.Orchestrator.run_task/1 with :callback"
     )}
  end

  defp check_self_terminate(_request), do: :ok

  defp ssh_key(request) do
    configured = Application.get_env(:ex_atlas, :lambda_labs, [])[:ssh_key_name]

    case Map.get(request.provider_opts, :ssh_key_name) ||
           Map.get(request.provider_opts, "ssh_key_name") || configured do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _ ->
        {:error,
         Error.new(:validation,
           provider: :lambda_labs,
           message:
             "Lambda needs exactly one SSH key name: pass provider_opts: %{ssh_key_name: name} " <>
               "or set config :ex_atlas, :lambda_labs, ssh_key_name: name"
         )}
    end
  end

  defp instance_types(ctx) do
    case Client.get(ctx, "/instance-types") do
      {:ok, %{} = types} -> {:ok, types}
      {:ok, _other} -> unexpected_body("GET /instance-types")
      {:error, _} = err -> err
    end
  end

  # Retried on a 429 only: a launch that answered 5xx or timed out may have
  # rented an instance already.
  defp launch(ctx, body) do
    case Client.post(ctx, "/instance-operations/launch", body, retry: &HTTP.retry_rate_limited/2) do
      {:ok, %{"instance_ids" => [id | _]}} when is_binary(id) ->
        {:ok, id}

      {:ok, _other} ->
        unexpected_body("POST /instance-operations/launch")

      {:error, %Error{} = error} ->
        {:error, withhold_echo(error)}
    end
  end

  # Lambda may echo a refused field, `user_data` included, in its error text,
  # quoted, escaped or cut short, so no substring check can find every echo.
  # An answered launch error keeps only its status and Lambda's error code.
  defp withhold_echo(%Error{status: status} = error) when is_integer(status) do
    code = code(error.raw)

    %{
      error
      | message:
          "Lambda refused the launch (#{code || "no error code"}); ExAtlas withholds " <>
            "Lambda's message, which can echo the request",
        raw: code && %{"error" => %{"code" => code}}
    }
  end

  defp withhold_echo(%Error{} = error), do: error

  defp code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp code(_raw), do: nil

  # --- helpers ---

  defp no_stop(fun),
    do: unsupported("Lambda instances cannot #{fun}; terminate it and spawn a new one")

  defp unsupported(message),
    do: {:error, Error.new(:unsupported, provider: :lambda_labs, message: message)}

  defp unexpected_body(call) do
    {:error, Error.new(:provider, provider: :lambda_labs, message: "unexpected body for #{call}")}
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
