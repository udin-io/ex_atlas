defmodule ExAtlas.Orchestrator.Adopter do
  @moduledoc """
  Re-adopts, at boot, the compute this node was tracking before it
  restarted.

  A `Task` with `restart: :transient`: it runs, it signals
  `ExAtlas.Orchestrator.Reaper`, and it exits `:normal` — there is nothing to
  keep alive afterwards. When the store cannot be read, the supervised child
  stays up and reads it again, from 5 s doubling to every 5 minutes, with no
  attempt limit. It starts inside `ExAtlas.Application`'s tree, so it
  runs concurrently with the rest of the boot rather than blocking it.

  ## What it does per record

  Exactly one reconciling question — "does the provider still know this id?" —
  and then it gets out of the way:

    * **404 / the provider does not know it** — delete the record. There is
      nothing to adopt and nothing to bill, and starting a tracker would only
      broadcast a death nobody is listening for.
    * **anything else**, for a record this node signed (an unsigned one, see
      below) — start a `ExAtlas.Orchestrator.ComputeServer` with
      `{:adopted, record}`, which recomputes the deadline from the record's
      wall-clock anchor and polls immediately. A resource that died during the
      downtime is then classified by the tracker's own first poll, through the
      existing `ExAtlas.Orchestrator.UpstreamStatus` →
      `ExAtlas.Orchestrator.TaskOutcome` → `terminate/2` path.

  That is deliberate: a fuller reconcile here would emit tidier events for pods
  that died while the node was down, at the cost of a second copy of the
  death-classification logic — which is the thing `UpstreamStatus` was
  extracted to prevent.

  A provider that cannot be reached at all is *not* a reason to skip adopting
  a signed record. It gets its tracker anyway, on a placeholder observation the
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
      until a later read succeeds**. A node that cannot tell which running
      pods are its own must never issue a DELETE. Sent once, on the first
      failure; the read that succeeds adopts and sends `:adoption_complete`.

  A record whose id a live tracker holds is left to that tracker, in every
  adoption: a retry runs minutes after boot, when a task spawned meanwhile may
  be renting a replacement for a pod that now reads 404.

  It records each outcome for its supervisor before it sends it, so a Reaper
  that restarts later in the boot, or was down when the signal went out,
  starts with the gate in the same state.

  ## Records of other owners

  A tracking store shared by several nodes holds every node's tasks. A node
  adopts only the records whose `:owner` is its own `:reap_owner`:

    * **Another owner's record** is left in the store, untracked, and never
      sent to the provider: a node with a wrong key sees 404 for every pod, and
      deleting the record of a live pod would let its owner's Reaper delete the
      pod after that owner's next restart. One info line per other owner lists
      its ids. When that owner's lease expires, `ExAtlas.Orchestrator.Lease`
      takes its signed records over and adopts them through `adopt_claimed/3`;
      with a store that has no leases, they stay until an operator deletes
      them.
    * **An unowned record** (version 1, or a node that had no `:reap_owner`) is
      claimed by the first node to adopt it, which writes its own owner into the
      record.
    * **An invalid `:reap_owner`** adopts nothing and keeps every record, as the
      Reaper reaps nothing while the owner is invalid.

  ## Records this node did not sign

  An adopted task deletes its pod at its deadline with this node's key, and
  whoever wrote the record chose the pod id. A record whose signature does not
  check (`ExAtlas.Orchestrator.TrackingStore.sealed?/1`) is adopted only when
  the provider reports, for the record's provider, what this node's Reaper
  would delete once untracked: a provider in `:reap_providers`, a pod that
  bills (`:provisioning` or `:running`), a node that has a `:reap_owner` or
  is not connected to others, and a name that starts with
  `:reap_name_prefix` and carries that owner. Any other unsigned record, and one whose pod the
  provider could not report, is skipped, kept, logged and not claimed. The
  next boot checks it again.

  The cluster test reads `Node.list/0` at boot, which may run before the
  cluster connects, and no peer is asked for a duplicate owner, as the
  Reaper's tick does.

  ## Records this build does not understand

  A record with a `:v` other than 1, 2 or 3, a `:mode` other than `:task`, or a
  provider that is neither built in nor a module declaring
  `@behaviour ExAtlas.Provider`, is skipped with a warning and **left in the
  store**. Deleting it would be worse than
  useless: the store entry is the only thing telling the Reaper that a live,
  prefix-matching pod belongs to this app.
  """

  use Task, restart: :transient

  require Logger

  alias ExAtlas.Orchestrator

  alias ExAtlas.Orchestrator.{ComputeServer, ComputeSupervisor, Ownership, Reaper, TrackingStore}
  alias ExAtlas.Config
  alias ExAtlas.Orchestrator.UpstreamStatus
  alias ExAtlas.Spec

  @doc false
  # The supervised child reads until the store answers; `run/1` alone reads
  # once.
  def start_link(opts \\ []),
    do: Task.start_link(__MODULE__, :run, [Keyword.put(opts, :retry, true)])

  @doc """
  Adopt everything in the tracking store, then signal the Reaper.

  Options:

    * `:store` — the `ExAtlas.Orchestrator.TrackingStore` implementation.
      Defaults to the configured one.
    * `:notify` — pid or registered name to send `:adoption_complete` /
      `:adoption_failed` to. Defaults to `ExAtlas.Orchestrator.Reaper`.
    * `:retry` — read the store again after a failed read, until it answers.
      Defaults to `false`; the child `ExAtlas.Orchestrator.Supervisor` starts
      sets it.
    * `:retry_after_ms` — the wait before the first retry. Defaults to 5 s.
      Each wait doubles, up to `:max_retry_after_ms` (default 5 minutes).
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    notify = Keyword.get(opts, :notify, Reaper)

    case Keyword.get(opts, :store) || TrackingStore.impl() do
      nil -> signal(notify, :adoption_complete)
      store -> adopt_all(store, notify, retry_plan(opts))
    end
  end

  @retry_after_ms 5_000
  @max_retry_after_ms 300_000

  defp retry_plan(opts) do
    if Keyword.get(opts, :retry, false) do
      # At least 1 ms: `Process.sleep/1` raises on a negative wait.
      max = max(Keyword.get(opts, :max_retry_after_ms, @max_retry_after_ms), 1)
      %{delay: max(min(Keyword.get(opts, :retry_after_ms, @retry_after_ms), max), 1), max: max}
    end
  end

  @doc """
  Adopt `records` that this node, as `owner`, just claimed from an owner whose
  lease expired (`ExAtlas.Orchestrator.Lease`), as a boot adopts its own: a
  record whose pod is gone is deleted, the rest get trackers. Signals no one.
  """
  @spec adopt_claimed([TrackingStore.record()], String.t(), module()) :: :ok
  def adopt_claimed(records, owner, store) do
    Enum.each(records, &adopt_one(&1, owner, store))
  end

  defp adopt_all(store, notify, plan) do
    case read_all(store) do
      {:ok, records} ->
        adopt_records(records, store, notify)

      {:error, reason} ->
        Logger.error(
          "[ExAtlas.Orchestrator.Adopter] tracking store could not be read " <>
            "(#{inspect(reason)}); adopting nothing, and reaping is off until it reads. " <>
            "Compute this node spawned before the restart is still running and billing. " <>
            next_try(plan)
        )

        signal(notify, :adoption_failed)

        if plan,
          do: retry(store, notify, plan, 2, System.monotonic_time(:millisecond)),
          else: :ok
    end
  end

  # No attempt limit: giving up would shut the Reaper for the rest of the boot.
  # Once capped, a store that stays down costs one read per 5 minutes.
  defp retry(store, notify, plan, attempt, since) do
    Process.sleep(plan.delay)

    case read_all(store) do
      {:ok, records} ->
        Logger.info(
          "[ExAtlas.Orchestrator.Adopter] tracking store read on attempt #{attempt} after " <>
            "#{span(System.monotonic_time(:millisecond) - since)}; adopting from #{length(records)} " <>
            "record(s). The Reaper reopens once adoption settles."
        )

        adopt_records(records, store, notify)

      {:error, reason} ->
        plan = %{plan | delay: min(plan.delay * 2, plan.max)}

        Logger.warning(
          "[ExAtlas.Orchestrator.Adopter] tracking store still unreadable (attempt #{attempt}): " <>
            "#{inspect(reason)}; reaping stays off. #{next_try(plan)}"
        )

        retry(store, notify, plan, attempt + 1, since)
    end
  end

  defp next_try(nil), do: "Nothing reads it again until the next boot."
  defp next_try(%{delay: delay}), do: "Next try in #{span(delay)}."

  defp span(ms) when ms < 1_000, do: "#{ms} ms"
  defp span(ms) when ms < 60_000, do: "#{div(ms, 1_000)} s"
  defp span(ms), do: "#{Float.round(ms / 60_000, 1)} min"

  defp adopt_records(records, store, notify) do
    case Ownership.owner() do
      {:ok, owner} -> adopt_owned(records, owner, store)
      {:error, error} -> log_invalid_owner(error)
    end

    signal(notify, :adoption_complete)
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
        "If that node is gone, a node with leases (the Ecto store) takes them over once its " <>
        "lease expires; otherwise delete the pods and records by hand."
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
    case store.all() do
      {:ok, records} when is_list(records) ->
        if List.improper?(records),
          do: {:error, {:unexpected_answer, :improper_list}},
          else: {:ok, records}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_answer, other}}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # One unreadable record must not cost the others their trackers. A record a
  # live tracker holds is that tracker's: a 404 for it means a respawn is
  # renting the replacement, and the tracker carries the record over itself.
  #
  # A record that changed in the store since `all/0` read it is adopted again
  # from what the store holds now, once; a record gone from the store was
  # removed by its tracker.
  defp adopt_one(record, owner, store, rereads \\ 1) do
    if tracked?(record) do
      :tracked
    else
      case adopt(record, owner, store) do
        {:changed, fresh} when rereads > 0 -> adopt_one(fresh, owner, store, rereads - 1)
        {:changed, _fresh} -> log_changing(record)
        result -> result
      end
    end
  rescue
    error -> log_skipped(record, error)
  catch
    :exit, reason -> log_skipped(record, {:exit, reason})
  end

  defp id_of(record) when is_map(record), do: Map.get(record, :id)
  defp id_of(record), do: record

  defp log_changing(record) do
    Logger.warning(
      "[ExAtlas.Orchestrator.Adopter] not adopting #{inspect(record.id)}: its record changed " <>
        "twice while this node adopted it. The record is kept, so the Reaper still treats " <>
        "the resource as ours."
    )
  end

  defp log_skipped(record, error) do
    Logger.error(
      "[ExAtlas.Orchestrator.Adopter] failed to adopt #{inspect(id_of(record))} " <>
        "(#{inspect(error)}); it is still running upstream. Its record is kept, so the " <>
        "Reaper will not terminate it."
    )
  end

  defp adopt(stored, owner, store) do
    case refusal(stored) do
      nil ->
        warn_stored_endpoint(stored)
        # Checked on the record as stored, before anything changes it. A
        # tracker respawns only from a record this node signed.
        record = Map.put(TrackingStore.upgrade(stored), :sealed, TrackingStore.sealed?(stored))
        adopt_by_owner(record, record[:owner], owner, store, stored)

      why ->
        skip(stored, why)
    end
  end

  @doc false
  # Why this build would not adopt `record`, or nil. `ExAtlas.Orchestrator.Lease`
  # asks before it claims a record, so it never owns one it cannot track.
  @spec refusal(map()) :: String.t() | nil
  def refusal(record) do
    cond do
      not TrackingStore.readable?(Map.get(record, :v)) ->
        "unknown schema version #{inspect(Map.get(record, :v))} " <>
          "(this build understands versions 1 to #{TrackingStore.version()})"

      Map.get(record, :mode) != :task ->
        "mode #{inspect(Map.get(record, :mode))} is not adoptable"

      not declared_provider?(record) ->
        "its provider is neither built in nor a module declaring ExAtlas.Provider"

      true ->
        nil
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
    case TrackingStore.ignored_opts(record) do
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
  defp adopt_by_owner(record, owner, owner, store, stored),
    do: reconcile(record, owner, store, false, stored)

  # An unowned record: the first node to adopt it claims it, so later boots on
  # other nodes skip it.
  defp adopt_by_owner(record, nil, owner, store, stored),
    do: reconcile(Map.put(record, :owner, owner), owner, store, true, stored)

  # Another node's task: no provider call, no delete, no tracker.
  defp adopt_by_owner(record, other, _owner, _store, _stored),
    do: {:other_owner, other, record.id}

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

  defp reconcile(record, owner, store, claim?, stored) do
    observation = observe(record)

    # A tracker started while the provider answered (a Lease claim, a second
    # adoption): the record is its own now. Otherwise act only on the record
    # the store holds now: `all/0` read it before this record's turn, and on a
    # retry minutes before.
    if tracked?(record) do
      :tracked
    else
      reconcile_current(store.get(record.id), record, observation, owner, store, claim?, stored)
    end
  end

  # The provider has forgotten the id entirely: `{:dead, _, nil}` is
  # `UpstreamStatus`'s way of saying there is nothing left to terminate,
  # whether that reads as `:vanished` or, on spot capacity, `:preempted`.
  defp reconcile_current(
         {:ok, stored},
         record,
         {:dead, _reason, nil},
         _owner,
         store,
         _claim?,
         stored
       ),
       do: store.delete(record.id)

  defp reconcile_current({:ok, stored}, record, observation, owner, store, claim?, stored),
    do: track(record, observation, owner, store, claim?)

  defp reconcile_current({:ok, fresh}, _record, _observation, _owner, _store, _claim?, _stale),
    do: {:changed, fresh}

  defp reconcile_current(:error, _record, _observation, _owner, _store, _claim?, _stale),
    do: :gone

  defp tracked?(record), do: match?({:ok, _pid}, Orchestrator.lookup(Map.get(record, :id)))

  defp track(record, observation, owner, store, claim?) do
    case unsigned_refusal(record, observation, owner) do
      nil ->
        if claim?, do: claim(record, store)
        start_tracker(record, compute(observation, record))

      why ->
        skip(record, why)
    end
  end

  # The claim lands before the tracker starts, so the tracker's own record
  # updates keep it, and after the check, so a refused record stays unowned.
  defp claim(record, store) do
    {sealed?, stored} = Map.pop(record, :sealed)
    # The tracker gets the values an older record holds; the store does not.
    store.put(TrackingStore.rewrite(stored, sealed?))
  end

  # Whoever wrote an unsigned record chose its id, and an adopted task deletes
  # that id with this node's key. So it adopts only a pod this node's Reaper
  # would delete too, judged on what the provider reports: a record field
  # proves nothing (issue 138).
  defp unsigned_refusal(%{sealed: true}, _observation, _owner), do: nil

  defp unsigned_refusal(_record, {:poll_failed, _error}, _owner),
    do:
      "its record is not signed by this node, and its pod could not be checked " <>
        "(the provider did not answer); the next boot checks again"

  defp unsigned_refusal(record, observation, owner) do
    provider = Keyword.fetch!(TrackingStore.observe_opts(record), :provider)

    case Reaper.refusal(provider, compute(observation, record), owner) do
      nil -> nil
      why -> "its record is not signed by this node, and #{why}"
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
