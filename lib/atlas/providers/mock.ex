defmodule Atlas.Providers.Mock do
  @moduledoc """
  In-memory provider for tests and demos.

  Every `Atlas.Provider` callback is implemented against an ETS-backed store.
  Useful for:

    * Unit tests that need a full provider without hitting the network.
    * Local development of LiveView UIs that spawn compute.
    * Validating that your user code is provider-agnostic (swap `:runpod` for
      `:mock` and everything should still work).

  The mock is **not** intended for production use. It simulates state transitions
  synchronously — pods are `:running` immediately after `spawn_compute/2`, jobs
  complete on the next `get_job/2`.

  ## Usage

      config :atlas, default_provider: :mock
      config :atlas, :mock, api_key: "anything"

      {:ok, compute} = Atlas.spawn_compute(gpu: :h100, image: "test", auth: :bearer)
      {:ok, _}       = Atlas.get_compute(compute.id)
      :ok            = Atlas.terminate(compute.id)

  ## Resetting between tests

      setup do
        Atlas.Providers.Mock.reset()
        :ok
      end
  """

  @behaviour Atlas.Provider

  alias Atlas.Auth.Token, as: AuthToken
  alias Atlas.Spec

  @table :atlas_mock_store

  @doc "Ensure the ETS table exists. Called automatically by every callback."
  def ensure_started do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:public, :named_table, :set, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _ref ->
        @table
    end
  end

  @doc "Clear all mock state. Call from test setup."
  def reset do
    ensure_started()
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def capabilities,
    do: [:spot, :serverless, :network_volumes, :http_proxy, :raw_tcp, :webhooks]

  @impl true
  def spawn_compute(%Spec.ComputeRequest{} = req, _ctx) do
    ensure_started()
    id = "mock-" <> random_id()
    auth = build_auth(req.auth)
    ports = build_ports(req.ports, id)

    compute = %Spec.Compute{
      id: id,
      provider: :mock,
      status: :running,
      public_ip: "203.0.113.1",
      ports: ports,
      gpu_type: Atom.to_string(req.gpu),
      gpu_count: req.gpu_count,
      cost_per_hour: 0.0,
      region: List.first(req.region_hints),
      image: req.image,
      name: req.name,
      auth: auth,
      created_at: DateTime.utc_now(),
      raw: %{request: req}
    }

    :ets.insert(@table, {{:compute, id}, compute})
    {:ok, compute}
  end

  @impl true
  def get_compute(id, _ctx) do
    ensure_started()

    case :ets.lookup(@table, {:compute, id}) do
      [{_, compute}] -> {:ok, compute}
      [] -> {:error, Atlas.Error.new(:not_found, provider: :mock, message: "no compute #{id}")}
    end
  end

  @impl true
  def list_compute(filters, _ctx) do
    ensure_started()

    computes =
      :ets.match_object(@table, {{:compute, :_}, :_})
      |> Enum.map(fn {_, c} -> c end)
      |> filter(filters)

    {:ok, computes}
  end

  @impl true
  def stop(id, _ctx), do: update_status(id, :stopped)

  @impl true
  def start(id, _ctx), do: update_status(id, :running)

  @impl true
  def terminate(id, _ctx) do
    ensure_started()

    case :ets.lookup(@table, {:compute, id}) do
      [{key, compute}] ->
        :ets.insert(@table, {key, %{compute | status: :terminated}})
        :ok

      [] ->
        {:error, Atlas.Error.new(:not_found, provider: :mock)}
    end
  end

  @impl true
  def run_job(%Spec.JobRequest{} = req, _ctx) do
    ensure_started()
    id = "job-" <> random_id()

    job = %Spec.Job{
      id: id,
      provider: :mock,
      endpoint: req.endpoint,
      status: :completed,
      output: %{"echo" => req.input},
      execution_time_ms: 0,
      delay_time_ms: 0,
      created_at: DateTime.utc_now(),
      raw: %{request: req}
    }

    :ets.insert(@table, {{:job, id}, job})
    {:ok, job}
  end

  @impl true
  def get_job(id, _ctx) do
    ensure_started()

    case :ets.lookup(@table, {:job, id}) do
      [{_, job}] -> {:ok, job}
      [] -> {:error, Atlas.Error.new(:not_found, provider: :mock)}
    end
  end

  @impl true
  def cancel_job(id, _ctx) do
    ensure_started()

    case :ets.lookup(@table, {:job, id}) do
      [{key, job}] ->
        :ets.insert(@table, {key, %{job | status: :cancelled}})
        :ok

      [] ->
        {:error, Atlas.Error.new(:not_found, provider: :mock)}
    end
  end

  @impl true
  def stream_job(id, ctx) do
    Stream.unfold(:start, fn
      :start ->
        case get_job(id, ctx) do
          {:ok, %Spec.Job{output: output}} -> {output, :done}
          _ -> nil
        end

      :done ->
        nil
    end)
  end

  @impl true
  def list_gpu_types(_ctx) do
    {:ok,
     [
       %Spec.GpuType{
         id: "mock-h100",
         provider: :mock,
         canonical: :h100,
         display_name: "Mock H100",
         memory_gb: 80,
         lowest_price_per_hour: 0.0,
         spot_price_per_hour: 0.0,
         stock: :high,
         cloud_type: :any
       }
     ]}
  end

  # --- helpers ---

  defp update_status(id, status) do
    ensure_started()

    case :ets.lookup(@table, {:compute, id}) do
      [{key, compute}] ->
        :ets.insert(@table, {key, %{compute | status: status}})
        :ok

      [] ->
        {:error, Atlas.Error.new(:not_found, provider: :mock)}
    end
  end

  defp build_auth(:none), do: nil

  defp build_auth(:bearer) do
    mint = AuthToken.mint()
    %{scheme: :bearer, token: mint.token, header: mint.header, hash: mint.hash}
  end

  defp build_auth(:signed_url), do: %{scheme: :signed_url, token: nil, header: nil, hash: nil}

  defp build_ports(ports, id) do
    Enum.map(ports, fn {port, protocol} ->
      %{
        internal: port,
        external: port,
        protocol: protocol,
        url:
          case protocol do
            :http -> "https://#{id}-#{port}.mock.local"
            :tcp -> "tcp://203.0.113.1:#{port}"
          end
      }
    end)
  end

  defp filter(computes, []), do: computes

  defp filter(computes, filters) do
    Enum.filter(computes, fn c ->
      Enum.all?(filters, fn
        {:status, s} -> c.status == s
        {:name, n} -> c.name == n
        {:region, r} -> c.region == r
        {:gpu, g} -> c.gpu_type == Atom.to_string(g)
        _ -> true
      end)
    end)
  end

  defp random_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
