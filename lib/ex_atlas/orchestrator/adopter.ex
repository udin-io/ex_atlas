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

  It records the outcome for its supervisor before it sends it, so a Reaper
  that restarts later in the boot, or was down when the signal went out,
  starts with the gate in the same state.

  ## Records of other owners

  A tracking store shared by several nodes holds every node's tasks. A node
  adopts only the records whose `:owner` is its own `:reap_owner`:

    * **Another owner's record** is left in the store, untracked, and never
      sent to the provider: a node with a wrong key sees 404 for every pod, and
      deleting the record of a live pod would let its owner's Reaper delete the
      pod after that owner's next restart. One info line per other owner lists
      its ids. A dead owner's pods and records stay until an operator deletes
      them.
    * **An unowned record** (version 1, or a node that had no `:reap_owner`) is
      claimed by the first node to adopt it, which writes its own owner into the
      record.
    * **An invalid `:reap_owner`** adopts nothing and keeps every record, as the
      Reaper reaps nothing while the owner is invalid.

  ## Records this build does not understand

  A record with a `:v` other than 1, 2 or 3, or a `:mode` other than `:task`, is
  skipped with a warning and **left in the store**. Deleting it would be worse than
  useless: the store entry is the only thing telling the Reaper that a live,
  prefix-matching pod belongs to this app.
  """

  use Task, restart: :transient

  require Logger

  alias ExAtlas.Orchestrator.{ComputeServer, ComputeSupervisor, Ownership, Reaper, TrackingStore}
  alias ExAtlas.Config
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
    case read_all(store) do
      {:ok, records} ->
        case Ownership.owner() do
          {:ok, owner} -> adopt_owned(records, owner, store)
          {:error, error} -> log_invalid_owner(error)
        end

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

  defp adopt_owned(records, owner, store) do
    records
    |> Enum.map(&adopt_one(&1, owner, store))
    |> Enum.flat_map(fn
      {:other_owner, other, id} -> [{other, id}]
      _adopted_or_skipped -> []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {other, ids} -> log_other_owner(other, ids) end)
  end

  defp log_other_owner(owner, ids) do
    Logger.info(
      "[ExAtlas.Orchestrator.Adopter] leaving #{length(ids)} record(s) of owner #{inspect(owner)} " <>
        "in the store, untracked on this node: #{Enum.map_join(ids, ", ", &inspect/1)}. Their owner adopts them. " <>
        "If that node is gone, delete the pods and records by hand."
    )
  end

  defp log_invalid_owner(error) do
    Logger.error(
      "[ExAtlas.Orchestrator.Adopter] #{error.message}; adopting nothing and keeping " <>
        "every record. The Reaper reaps nothing while the owner is invalid."
    )
  end

  # This runs inside the host's supervision tree during *their* boot, against a
  # store they may have written and a provider API that may be down. Neither is
  # allowed to take their application down, and a `restart: :transient` task
  # that keeps crashing would do exactly that. So both boundaries are contained
  # here, and every containment resolves towards the safe answer: adopt nothing
  # and let the Reaper stay shut rather than guess.
  defp read_all(store) do
    store.all()
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # One unreadable record must not cost the others their trackers.
  defp adopt_one(record, owner, store) do
    adopt(record, owner, store)
  rescue
    error -> log_skipped(record, error)
  catch
    :exit, reason -> log_skipped(record, {:exit, reason})
  end

  defp log_skipped(record, error) do
    Logger.error(
      "[ExAtlas.Orchestrator.Adopter] failed to adopt #{inspect(Map.get(record, :id))} " <>
        "(#{inspect(error)}); it is still running upstream. Its record is kept, so the " <>
        "Reaper will not terminate it."
    )
  end

  defp adopt(record, owner, store) do
    cond do
      not TrackingStore.readable?(record.v) ->
        skip(
          record,
          "unknown schema version #{record.v} " <>
            "(this build understands versions 1 to #{TrackingStore.version()})"
        )

      record.mode != :task ->
        skip(record, "mode #{inspect(record.mode)} is not adoptable")

      not declared_provider?(record) ->
        skip(record, "its provider is neither built in nor a module declaring ExAtlas.Provider")

      true ->
        warn_stored_endpoint(record)
        adopt_by_owner(TrackingStore.upgrade(record), record[:owner], owner, store)
    end
  end

  # The provider is code this node runs, named by whoever wrote the store. Only
  # a module that opted in by declaring the behaviour qualifies, never one that
  # merely exports `capabilities/0`.
  defp declared_provider?(record) do
    case Keyword.get(TrackingStore.observe_opts(record), :provider) do
      provider when is_atom(provider) ->
        Map.has_key?(Config.builtin_providers(), provider) or declares_provider?(provider)

      _not_an_atom ->
        false
    end
  end

  defp declares_provider?(module) do
    Code.ensure_loaded?(module) and
      ExAtlas.Provider in (module.module_info(:attributes)
                           |> Keyword.get_values(:behaviour)
                           |> List.flatten())
  end

  # Names the keys alone: their values came from the store's writer.
  defp warn_stored_endpoint(record) do
    case TrackingStore.stored_endpoint_opts(record) do
      [] ->
        :ok

      keys ->
        Logger.warning(
          "[ExAtlas.Orchestrator.Adopter] adopting #{inspect(record.id)} without its stored " <>
            "#{Enum.map_join(keys, ", ", &inspect/1)}: an adopted task calls its provider " <>
            "where config :ex_atlas, #{inspect(record.provider)} points."
        )
    end
  end

  # Same owner, or no owner on either side: ours, as before.
  defp adopt_by_owner(record, owner, owner, store), do: reconcile(record, store)

  # An unowned record: the first node to adopt it claims it, so later boots on
  # other nodes skip it. The claim lands before the tracker starts, so the
  # tracker's own record updates keep it.
  defp adopt_by_owner(record, nil, owner, store) do
    claimed = Map.put(record, :owner, owner)
    # The tracker gets the values an older record holds; the store does not.
    store.put(TrackingStore.scrub_record(claimed))
    reconcile(claimed, store)
  end

  # Another node's task: no provider call, no delete, no tracker.
  defp adopt_by_owner(record, other, _owner, _store), do: {:other_owner, other, record.id}

  # Skipped, but never deleted: the store entry is the only thing telling the
  # Reaper that a live, prefix-matching pod belongs to this app, and a record
  # we cannot interpret is far more likely to be from a newer build of this
  # same app than to be junk.
  defp skip(record, why) do
    Logger.warning(
      "[ExAtlas.Orchestrator.Adopter] not adopting #{Map.get(record, :id, "?")}: #{why}. " <>
        "The record is kept so the Reaper still treats the resource as ours."
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

  defp signal(notify, message) do
    :ok = Reaper.record_adoption(outcome(message))
    send_signal(notify, message)
  end

  defp outcome(:adoption_complete), do: :settled
  defp outcome(:adoption_failed), do: :failed

  defp send_signal(nil, _message), do: :ok

  defp send_signal(pid, message) when is_pid(pid) do
    send(pid, message)
    :ok
  end

  defp send_signal(name, message) when is_atom(name),
    do: send_signal(Process.whereis(name), message)
end
