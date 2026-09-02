defmodule ExAtlas.Orchestrator.Adopter do
  @moduledoc """
  Re-adopts, once at boot, the compute this node was tracking before it
  restarted.

  A `Task` with `restart: :transient`: it runs, it signals
  `ExAtlas.Orchestrator.Reaper`, and it exits `:normal` — there is nothing to
  keep alive afterwards. It starts inside `ExAtlas.Application`'s tree, so it
  runs concurrently with the rest of the boot rather than blocking it.

  ## What it does per record

  Exactly one reconciling question — "does the provider still know this id?" —
  and then it gets out of the way:

    * **404 / the provider does not know it** — delete the record. There is
      nothing to adopt and nothing to bill, and starting a tracker would only
      broadcast a death nobody is listening for.
    * **anything else** — start a `ExAtlas.Orchestrator.ComputeServer` with
      `{:adopted, record}`, which recomputes the deadline from the record's
      wall-clock anchor and polls immediately. A resource that died during the
      downtime is then classified by the tracker's own first poll, through the
      existing `ExAtlas.Orchestrator.UpstreamStatus` →
      `ExAtlas.Orchestrator.TaskOutcome` → `terminate/2` path.

  That is deliberate: a fuller reconcile here would emit tidier events for pods
  that died while the node was down, at the cost of a second copy of the
  death-classification logic — which is the thing `UpstreamStatus` was
  extracted to prevent.

  A provider that cannot be reached at all is *not* a reason to skip adoption.
  The record gets its tracker anyway, on a placeholder observation the
  immediate first poll corrects, because the carried deadline is the one thing
  that must be re-armed even when the provider is having a bad day.

  ## The race with the Reaper, closed explicitly

  Between "the store is loaded" and "the trackers are running" a live resource
  of ours has no registry entry, which is exactly what the Reaper terminates.
  `:reap_grace_ms` cannot help: it is keyed off `created_at`, and adopted pods
  are by definition old.

  So the Reaper starts gated — it reaps nothing until this task tells it
  adoption has settled — and this task always tells it something:

    * `:adoption_complete` — every record was accounted for; reap normally.
    * `:adoption_failed` — the store could not be read, so **nothing is reaped
      for the rest of this boot**. A node that cannot tell which running pods
      are its own must never issue a DELETE.

  ## Records this build does not understand

  A record with an unknown `:v`, or a `:mode` other than `:task`, is skipped
  with a warning and **left in the store**. Deleting it would be worse than
  useless: the store entry is the only thing telling the Reaper that a live,
  prefix-matching pod belongs to this app.
  """

  use Task, restart: :transient

  require Logger

  alias ExAtlas.Orchestrator.{ComputeServer, ComputeSupervisor, Reaper, TrackingStore}
  alias ExAtlas.Orchestrator.UpstreamStatus
  alias ExAtlas.Spec

  @doc false
  def start_link(opts \\ []), do: Task.start_link(__MODULE__, :run, [opts])

  @doc """
  Adopt everything in the tracking store, then signal the Reaper.

  Options:

    * `:store` — the `ExAtlas.Orchestrator.TrackingStore` implementation.
      Defaults to the configured one.
    * `:notify` — pid or registered name to send `:adoption_complete` /
      `:adoption_failed` to. Defaults to `ExAtlas.Orchestrator.Reaper`.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    notify = Keyword.get(opts, :notify, Reaper)

    case Keyword.get(opts, :store) || TrackingStore.impl() do
      nil -> signal(notify, :adoption_complete)
      store -> adopt_all(store, notify)
    end
  end

  defp adopt_all(store, notify) do
    case store.all() do
      {:ok, records} ->
        Enum.each(records, &adopt(&1, store))
        signal(notify, :adoption_complete)

      {:error, reason} ->
        Logger.error(
          "[ExAtlas.Orchestrator.Adopter] tracking store could not be read " <>
            "(#{inspect(reason)}); adopting nothing and DISABLING the Reaper for this boot. " <>
            "Compute this node spawned before the restart is still running and billing — " <>
            "check your provider for pods matching :reap_name_prefix."
        )

        signal(notify, :adoption_failed)
    end
  end

  defp adopt(record, store) do
    cond do
      record.v != TrackingStore.version() -> skip(record, "unknown schema version #{record.v}")
      record.mode != :task -> skip(record, "mode #{inspect(record.mode)} is not adoptable")
      true -> reconcile(record, store)
    end
  end

  # Skipped, but never deleted: the store entry is the only thing telling the
  # Reaper that a live, prefix-matching pod belongs to this app, and a record
  # we cannot interpret is far more likely to be from a newer build of this
  # same app than to be junk.
  defp skip(record, why) do
    Logger.warning(
      "[ExAtlas.Orchestrator.Adopter] not adopting #{Map.get(record, :id, "?")}: #{why} " <>
        "(this build understands version #{TrackingStore.version()}). The record is kept " <>
        "so the Reaper still treats the resource as ours."
    )
  end

  defp reconcile(record, store) do
    case observe(record) do
      # The provider has forgotten the id entirely: `{:dead, _, nil}` is
      # `UpstreamStatus`'s way of saying there is nothing left to terminate,
      # whether that reads as `:vanished` or, on spot capacity, `:preempted`.
      {:dead, _reason, nil} ->
        store.delete(record.id)

      observation ->
        start_tracker(record, compute(observation, record))
    end
  end

  defp observe(record) do
    UpstreamStatus.observe(record.id, TrackingStore.observe_opts(record))
  rescue
    # The provider raised rather than answered — most often a key that resolves
    # to nil, which at boot is a misconfiguration rather than news about the
    # resource. Adopt regardless: the tracker's own poll will keep asking, and
    # in the meantime the deadline is armed.
    error -> {:poll_failed, error}
  end

  defp compute({:alive, compute}, _record), do: compute
  defp compute({:dead, _reason, compute}, _record), do: compute

  defp compute({:poll_failed, error}, record) do
    Logger.warning(
      "[ExAtlas.Orchestrator.Adopter] could not reach the provider for #{record.id} " <>
        "(#{inspect(error)}); adopting on the record alone. The tracker's first poll will " <>
        "correct this, and the carried deadline is armed either way."
    )

    # A placeholder, corrected by the immediate first poll. `:provisioning`
    # rather than `:running` so nothing downstream treats an unverified
    # resource as ready.
    %Spec.Compute{id: record.id, provider: record.provider, status: :provisioning}
  end

  defp start_tracker(record, compute) do
    child = {ComputeServer, {:adopted, Map.put(record, :compute, compute)}}

    case DynamicSupervisor.start_child(ComputeSupervisor, child) do
      {:ok, _pid} ->
        :ok

      {:ok, _pid, _info} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        # The record stays: a resource we could not re-track is still ours, and
        # the store entry is what stops the Reaper from deleting it.
        Logger.error(
          "[ExAtlas.Orchestrator.Adopter] could not start a tracker for #{record.id} " <>
            "(#{inspect(reason)}); it is still running upstream and is no longer tracked."
        )
    end
  end

  defp signal(nil, _message), do: :ok

  defp signal(pid, message) when is_pid(pid) do
    send(pid, message)
    :ok
  end

  defp signal(name, message) when is_atom(name), do: signal(Process.whereis(name), message)
end
