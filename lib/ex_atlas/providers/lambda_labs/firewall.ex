defmodule ExAtlas.Providers.LambdaLabs.Firewall do
  @moduledoc """
  One Lambda firewall ruleset per instance, opening the instance's `:ports`.

  Lambda's firewall admits only SSH by default. A spawn with `:ports` creates
  a ruleset named `atlas-<instance name>-<suffix>` and launches the instance
  with it attached. A failed launch deletes the ruleset.

  The sweep skips a ruleset younger than 5 minutes: another spawn may have
  created it a moment ago and not launched yet. It deletes at most 10 per
  spawn, since Lambda allows about one request a second.

  Lambda applies no firewall rules in `us-south-1`, so a spawn there creates
  no ruleset.
  """

  require Logger

  alias ExAtlas.Providers.HTTP
  alias ExAtlas.Providers.LambdaLabs.Client
  alias ExAtlas.Spec

  @prefix "atlas-"
  @max_name 64
  @no_firewall_region "us-south-1"
  @grace_seconds 300
  @sweep_limit 10

  @doc """
  Create the ruleset that opens `request.ports` in `region`, after sweeping
  unused ones. `{:ok, nil}` when there are no ports or the region has no
  firewall. A failed create is an error; a failed sweep is not.
  """
  @spec open(ExAtlas.Provider.ctx(), Spec.ComputeRequest.t(), [map()], String.t()) ::
          {:ok, String.t() | nil} | {:error, ExAtlas.Error.t()}
  def open(_ctx, _request, [], _region), do: {:ok, nil}
  def open(_ctx, _request, _rules, @no_firewall_region), do: {:ok, nil}

  def open(ctx, request, rules, region) do
    sweep(ctx)

    body = %{"name" => name(request.name), "region" => region, "rules" => rules}

    case Client.post(ctx, "/firewall-rulesets", body, retry: &HTTP.retry_rate_limited/2) do
      {:ok, %{"id" => id}} when is_binary(id) ->
        {:ok, id}

      {:ok, _other} ->
        {:error,
         ExAtlas.Error.new(:provider,
           provider: :lambda_labs,
           message: "unexpected body for POST /firewall-rulesets"
         )}

      {:error, _} = err ->
        err
    end
  end

  @doc "Add the ruleset to a launch body. `nil` leaves the body as it is."
  @spec attach(map(), String.t() | nil) :: map()
  def attach(body, nil), do: body
  def attach(body, id), do: Map.put(body, "firewall_rulesets", [%{"id" => id}])

  @doc """
  Delete a ruleset. Always `:ok`: a ruleset left behind is not the caller's error.
  """
  @spec delete(ExAtlas.Provider.ctx(), String.t() | nil) :: :ok
  def delete(_ctx, nil), do: :ok

  def delete(ctx, id) do
    case Client.delete(ctx, "/firewall-rulesets/#{URI.encode(id, &URI.char_unreserved?/1)}") do
      {:ok, _} ->
        :ok

      {:error,
       %ExAtlas.Error{raw: %{"error" => %{"code" => "firewall-rulesets/firewall-ruleset-in-use"}}}} ->
        :ok

      {:error, error} ->
        Logger.warning("Lambda ruleset #{id} not deleted: #{Exception.message(error)}")
        :ok
    end
  end

  defp sweep(ctx) do
    with {:ok, rulesets} when is_list(rulesets) <- Client.get(ctx, "/firewall-rulesets") do
      now = DateTime.utc_now()

      rulesets
      |> Enum.filter(&(atlas?(&1) and instance_ids(&1) == [] and old?(&1, now)))
      |> Enum.take(@sweep_limit)
      |> Enum.each(&delete(ctx, &1["id"]))
    end

    :ok
  end

  defp atlas?(%{"name" => name, "id" => id}) when is_binary(name) and is_binary(id),
    do: String.starts_with?(name, @prefix)

  defp atlas?(_ruleset), do: false

  defp instance_ids(%{"instance_ids" => ids}) when is_list(ids), do: ids
  # A ruleset that does not say which instances use it is treated as in use.
  defp instance_ids(_ruleset), do: [:unknown]

  defp old?(%{"created" => created}, now) when is_binary(created) do
    case DateTime.from_iso8601(created) do
      {:ok, at, _offset} -> DateTime.diff(now, at) >= @grace_seconds
      _ -> false
    end
  end

  defp old?(_ruleset, _now), do: false

  defp name(instance_name) do
    suffix = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    case instance_name do
      nil ->
        @prefix <> suffix

      name ->
        room = @max_name - String.length(@prefix) - String.length(suffix) - 1
        @prefix <> String.slice(name, 0, room) <> "-" <> suffix
    end
  end
end
