defmodule ExAtlas.Test.FaultyProvider do
  @moduledoc """
  An `ExAtlas.Provider` that delegates to `ExAtlas.Providers.Mock` until a
  fault is armed for one of its callbacks.

  `ExAtlas.Providers.Mock` can simulate what a *cloud* does (a pod that fails,
  stops or disappears). It cannot simulate what an *API* does — hanging,
  raising, refusing to spawn — and those are exactly the paths that decide
  whether a tracker tears down a live GPU. This double covers them.

  Faults live in application env, not the process dictionary, because they are
  armed from the test process and hit inside the tracker's poll task:

      FaultyProvider.arm(:get_compute, {:block, self()})
      assert_receive {:blocked, :get_compute, task}
      send(task, :release)

  Available faults:

    * `{:block, pid}` — send `{:blocked, callback, self()}` to `pid` and wait
      for `:release` before delegating. Lets a test hold a call open with no
      sleeps and no timing assumptions.
    * `{:block_after, pid}` — the same, but *after* delegating: the provider
      has already done the work and the caller has not seen the answer yet.
      That is the window in which a resource exists upstream with nothing
      tracking it locally.
    * `:raise` — raise, the way `Client.fetch_key!/1` does on a missing key.
    * `{:error, error}` — return `{:error, error}`.
  """

  @behaviour ExAtlas.Provider

  alias ExAtlas.Providers.Mock

  @env_key :faulty_provider_faults

  @doc "Arm `fault` for `callback`."
  def arm(callback, fault) do
    Application.put_env(:ex_atlas, @env_key, Map.put(faults(), callback, fault))
  end

  @doc "Clear every armed fault."
  def reset, do: Application.delete_env(:ex_atlas, @env_key)

  @impl true
  def spawn_compute(req, ctx),
    do: with_fault(:spawn_compute, fn -> Mock.spawn_compute(req, ctx) end)

  @impl true
  def get_compute(id, ctx), do: with_fault(:get_compute, fn -> Mock.get_compute(id, ctx) end)

  @impl true
  def list_compute(filters, ctx), do: Mock.list_compute(filters, ctx)

  @impl true
  def stop(id, ctx), do: Mock.stop(id, ctx)

  @impl true
  def start(id, ctx), do: Mock.start(id, ctx)

  @impl true
  def terminate(id, ctx), do: with_fault(:terminate, fn -> Mock.terminate(id, ctx) end)

  @impl true
  def run_job(req, ctx), do: Mock.run_job(req, ctx)

  @impl true
  def get_job(id, ctx), do: Mock.get_job(id, ctx)

  @impl true
  def cancel_job(id, ctx), do: Mock.cancel_job(id, ctx)

  @impl true
  def stream_job(id, ctx), do: Mock.stream_job(id, ctx)

  @impl true
  def list_gpu_types(ctx), do: Mock.list_gpu_types(ctx)

  @impl true
  def capabilities, do: Mock.capabilities()

  defp with_fault(callback, delegate) do
    case Map.get(faults(), callback) do
      nil ->
        delegate.()

      {:block, pid} ->
        send(pid, {:blocked, callback, self()})

        receive do
          :release -> delegate.()
        end

      {:block_after, pid} ->
        result = delegate.()
        send(pid, {:blocked, callback, self()})

        receive do
          :release -> result
        end

      :raise ->
        raise "simulated #{callback} failure"

      {:error, error} ->
        {:error, error}
    end
  end

  defp faults, do: Application.get_env(:ex_atlas, @env_key, %{})
end
