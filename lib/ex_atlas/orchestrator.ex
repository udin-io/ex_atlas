defmodule ExAtlas.Orchestrator do
  @moduledoc """
  Opt-in OTP orchestration for transient-per-user compute sessions.

  The core `ExAtlas` API is stateless — each call hits the provider directly. The
  orchestrator adds one lightweight `GenServer` per spawned resource. That server:

    * Holds the resource's metadata (id, auth handle, proxy URL, user context).
    * Heartbeats the resource via `touch/1` so idle sessions auto-terminate.
    * Traps exits and calls `ExAtlas.terminate/2` on shutdown, guaranteeing no
      leaked pods.
    * Broadcasts state changes over `Phoenix.PubSub` so LiveViews can react.

  The full supervision tree (`Registry` + `DynamicSupervisor` + `PubSub` + `Reaper`)
  only starts when you opt in:

      # config/config.exs
      config :ex_atlas, start_orchestrator: true

  When opted out (the default), ExAtlas boots with no processes — library-only
  consumers never pay for processes they don't use.

  ## Spawning a tracked resource

      {:ok, pid, compute} =
        ExAtlas.Orchestrator.spawn(
          provider: :runpod,
          gpu: :h100,
          image: "pytorch/pytorch:2.5.0-cuda12.1-cudnn9-runtime",
          ports: [{8000, :http}],
          auth: :bearer,
          user_id: current_user.id,
          idle_ttl_ms: 15 * 60_000
        )

      # LiveView can subscribe for state changes:
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:" <> compute.id)

  ## Heartbeating

      # Any time the user is still actively using the session:
      ExAtlas.Orchestrator.touch(compute.id)

  Missing a heartbeat for `idle_ttl_ms` triggers graceful termination.

  ## Manual termination

      :ok = ExAtlas.Orchestrator.stop_tracked(compute.id)
  """

  alias ExAtlas.Orchestrator.{ComputeRegistry, ComputeServer, ComputeSupervisor}

  @doc """
  Spawn a compute resource under supervision.

  Returns `{:ok, pid, compute}` where `pid` is the tracking `GenServer` and
  `compute` is the `ExAtlas.Spec.Compute` normally returned by `ExAtlas.spawn_compute/1`.
  """
  @spec spawn(keyword()) ::
          {:ok, pid(), ExAtlas.Spec.Compute.t()}
          | {:error, term()}
  def spawn(opts) do
    ensure_running!()

    with {:ok, compute} <- ExAtlas.spawn_compute(opts) do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          ComputeSupervisor,
          {ComputeServer, {compute, opts}}
        )

      {:ok, pid, compute}
    end
  end

  @doc "Record activity so the idle-reaper keeps the resource alive."
  @spec touch(String.t()) :: :ok | {:error, :not_tracked}
  def touch(id) do
    case lookup(id) do
      {:ok, pid} -> ComputeServer.touch(pid)
      :error -> {:error, :not_tracked}
    end
  end

  @doc "Fetch the latest tracked state for a resource."
  @spec info(String.t()) :: {:ok, map()} | {:error, :not_tracked}
  def info(id) do
    case lookup(id) do
      {:ok, pid} -> {:ok, ComputeServer.info(pid)}
      :error -> {:error, :not_tracked}
    end
  end

  @doc "Gracefully stop tracking and terminate the upstream resource."
  @spec stop_tracked(String.t()) :: :ok | {:error, :not_tracked}
  def stop_tracked(id) do
    case lookup(id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(ComputeSupervisor, pid)
        :ok

      :error ->
        {:error, :not_tracked}
    end
  end

  @doc "Return the list of currently-tracked resource ids."
  @spec list_ids() :: [String.t()]
  def list_ids do
    ensure_running!()

    Registry.select(ComputeRegistry, [{{{:compute, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  @doc false
  def lookup(id) do
    case Registry.lookup(ComputeRegistry, {:compute, id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp ensure_running! do
    unless Application.get_env(:ex_atlas, :start_orchestrator, false) do
      raise "ExAtlas.Orchestrator is not started. Set `config :ex_atlas, start_orchestrator: true` " <>
              "and ensure :ex_atlas is in your extra_applications."
    end
  end
end
