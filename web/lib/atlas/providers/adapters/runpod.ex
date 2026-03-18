defmodule Atlas.Providers.Adapters.RunPod do
  @moduledoc """
  RunPod provider adapter implementation.

  RunPod pods are treated as both apps and machines since each pod
  is a single compute unit (unlike Fly where apps contain machines).
  """

  @behaviour Atlas.Providers.Adapter

  alias Atlas.Providers.Adapters.RunPod.{Client, Normalizer}

  @impl true
  def test_connection(credential) do
    client = Client.new(credential.api_token)

    case Client.list_pods(client) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "Invalid API key"}
      {:ok, %{status: 403}} -> {:error, "Access forbidden - check API key permissions"}
      {:ok, %{status: status}} -> {:error, "Unexpected status: #{status}"}
      {:error, reason} -> {:error, "Connection failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def list_apps(credential) do
    client = Client.new(credential.api_token)

    case Client.list_pods(client) do
      {:ok, %{status: 200, body: pods}} when is_list(pods) ->
        normalized = Enum.map(pods, &Normalizer.normalize_pod_as_app(&1, credential))
        {:ok, normalized}

      {:ok, %{status: 200, body: %{"pods" => pods}}} when is_list(pods) ->
        normalized = Enum.map(pods, &Normalizer.normalize_pod_as_app(&1, credential))
        {:ok, normalized}

      {:ok, %{status: status, body: body}} ->
        {:error, "Failed to list pods (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def list_machines(credential, app_provider_id) do
    # For RunPod, each pod IS the machine - find it by ID
    client = Client.new(credential.api_token)

    case Client.get_pod(client, app_provider_id) do
      {:ok, %{status: 200, body: pod}} when is_map(pod) ->
        normalized = Normalizer.normalize_pod_as_machine(pod, credential)
        {:ok, [normalized]}

      {:ok, %{status: 404}} ->
        {:ok, []}

      {:ok, %{status: status, body: body}} ->
        {:error, "Failed to get pod (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def list_volumes(_credential, _app_provider_id) do
    # Volumes are at the account level for RunPod, not per-app
    {:ok, []}
  end

  @impl true
  def list_storage_buckets(credential) do
    client = Client.new(credential.api_token)

    case Client.list_network_volumes(client) do
      {:ok, %{status: 200, body: volumes}} when is_list(volumes) ->
        normalized = Enum.map(volumes, &Normalizer.normalize_network_volume(&1, credential))
        {:ok, normalized}

      {:ok, %{status: 200, body: %{"networkVolumes" => volumes}}} when is_list(volumes) ->
        normalized = Enum.map(volumes, &Normalizer.normalize_network_volume(&1, credential))
        {:ok, normalized}

      {:ok, %{status: status, body: body}} ->
        {:error, "Failed to list network volumes (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end
end
