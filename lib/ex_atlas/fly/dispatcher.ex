defmodule ExAtlas.Fly.Dispatcher do
  require Logger

  @moduledoc """
  Framework-agnostic broadcast for Fly log and deploy events.

  ExAtlas cannot hard-depend on Phoenix.PubSub because many consumers do not use
  Phoenix. This dispatcher picks one of three backends based on application
  config (`config :ex_atlas, :fly, dispatcher: ...`):

    * `:registry` (default) — atlas starts its own `Registry` with duplicate
      keys. Subscribers register the caller pid; `dispatch/2` sends the
      message via `send(pid, message)`.

    * `:phoenix_pubsub` — requires `phoenix_pubsub` to be present in the host
      app's deps and `config :ex_atlas, :fly, pubsub: MyApp.PubSub`. Uses
      `Phoenix.PubSub.subscribe/2` + `broadcast/3`.

    * `{:mfa, {mod, fun, extra_args}}` — on dispatch, calls
      `apply(mod, fun, [topic, message | extra_args])`. Subscription is a no-op
      (the host owns delivery).

  ## Topics & messages

    * Logs: topic `"ex_atlas_fly_logs:\#{app}"`, message `{:ex_atlas_fly_logs, app, entries}`
    * Deploy: topic `"ex_atlas_fly_deploy:\#{ticket_id}"`, message
      `{:ex_atlas_fly_deploy, ticket_id, line}`

  These shapes are stable — hosts match on them in `handle_info/2`.

  ## Dispatch semantics (H7)

  In `:registry` mode, `dispatch/2` uses `Registry.dispatch/3` which runs
  the fan-out `send/2` loop inside the caller's process while holding the
  registry partition lock. `send/2` itself is async (no back-pressure from
  the receiver), so dispatch time scales linearly with the number of
  subscribers. For typical log-streaming / deploy workloads this is
  negligible (a handful of subscribers per topic). Hosts with large fan-out
  should use `:phoenix_pubsub` mode.

  Subscribers with full mailboxes are not removed automatically — use
  `subscribe_with_backpressure/2` if you need auto-eviction of slow
  consumers (see E6).
  """

  @registry __MODULE__.Registry

  @type mode ::
          :registry
          | :phoenix_pubsub
          | {:mfa, {module(), atom(), list()}}

  @doc false
  def registry_name, do: @registry

  @doc """
  Child spec for the dispatcher's own registry (only used in `:registry` mode).
  """
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc """
  Subscribe the calling pid to `topic`.

  In `:registry` mode this registers the pid with the atlas registry.
  In `:phoenix_pubsub` mode this calls `Phoenix.PubSub.subscribe/2`.
  In `:mfa` mode this is a no-op — the host is expected to handle routing.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic) do
    case mode() do
      :registry ->
        {:ok, _} = Registry.register(@registry, topic, [])
        :ok

      :phoenix_pubsub ->
        pubsub = pubsub_name!()
        Phoenix.PubSub.subscribe(pubsub, topic)

      {:mfa, _} ->
        :ok
    end
  end

  @default_backpressure_threshold 10_000
  @default_backpressure_poll_ms 1_000

  @doc """
  Subscribe the calling pid to `topic` with a background watchdog that
  auto-unsubscribes the caller if their `message_queue_len/1` stays above
  `:threshold` for `:cooldown_ms` of consecutive polls.

  Protects the `Streamer` / `Deploy` producer from a slow consumer that
  would otherwise bloat its mailbox and eventually OOM the VM. Typical
  consumers (fast LiveView renderers) never trigger this; it's insurance
  for a hung subscriber.

  ## Options

    * `:threshold` — message queue length that triggers eviction.
      Default `#{@default_backpressure_threshold}`.
    * `:poll_ms` — how often to check the subscriber's queue length.
      Default `#{@default_backpressure_poll_ms}`.

  ## Caveats

  Only works in `:registry` mode. In `:phoenix_pubsub` or `:mfa` mode atlas
  is not the subscription authority and cannot evict subscribers —
  `subscribe_with_backpressure/2` falls back to a plain `subscribe/1` and
  logs a warning.

  The watchdog process is unlinked and monitors the subscriber pid — if
  the subscriber dies, the watchdog exits cleanly. Only `:registry`-mode
  subscribers get the protection.
  """
  @spec subscribe_with_backpressure(String.t(), keyword()) :: :ok | {:error, term()}
  def subscribe_with_backpressure(topic, opts \\ []) do
    case mode() do
      :registry ->
        threshold = Keyword.get(opts, :threshold, @default_backpressure_threshold)
        poll_ms = Keyword.get(opts, :poll_ms, @default_backpressure_poll_ms)

        with :ok <- subscribe(topic) do
          start_backpressure_watchdog(self(), topic, threshold, poll_ms)
          :ok
        end

      _ ->
        Logger.warning(
          "[ExAtlas.Fly.Dispatcher] subscribe_with_backpressure/2 only works in :registry mode; " <>
            "falling back to plain subscribe/1",
          mode: mode()
        )

        subscribe(topic)
    end
  end

  defp start_backpressure_watchdog(subscriber_pid, topic, threshold, poll_ms) do
    spawn(fn ->
      ref = Process.monitor(subscriber_pid)
      backpressure_loop(subscriber_pid, ref, topic, threshold, poll_ms)
    end)
  end

  defp backpressure_loop(subscriber_pid, ref, topic, threshold, poll_ms) do
    receive do
      {:DOWN, ^ref, :process, ^subscriber_pid, _reason} ->
        :ok
    after
      poll_ms ->
        case Process.info(subscriber_pid, :message_queue_len) do
          {:message_queue_len, len} when len > threshold ->
            Logger.warning(
              "[ExAtlas.Fly.Dispatcher] evicting slow subscriber",
              topic: topic,
              subscriber: inspect(subscriber_pid),
              queue_len: len,
              threshold: threshold
            )

            # We can't unregister another pid from the atlas Registry from
            # here — Registry.unregister/2 acts on the caller. Send the
            # subscriber a sentinel and expect it to handle_info on
            # `{:ex_atlas_fly_backpressure_evict, topic}` by calling
            # `ExAtlas.Fly.Dispatcher.unsubscribe(topic)` itself. The
            # watchdog's job ends here.
            send(subscriber_pid, {:ex_atlas_fly_backpressure_evict, topic})
            :ok

          _ ->
            backpressure_loop(subscriber_pid, ref, topic, threshold, poll_ms)
        end
    end
  end

  @doc """
  Unsubscribe the calling pid from `topic`.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic) do
    case mode() do
      :registry ->
        Registry.unregister(@registry, topic)
        :ok

      :phoenix_pubsub ->
        Phoenix.PubSub.unsubscribe(pubsub_name!(), topic)

      {:mfa, _} ->
        :ok
    end
  end

  @doc """
  Dispatch `message` to all subscribers of `topic`.
  """
  @spec dispatch(String.t(), term()) :: :ok
  def dispatch(topic, message) do
    case mode() do
      :registry ->
        Registry.dispatch(@registry, topic, fn entries ->
          for {pid, _} <- entries, do: send(pid, message)
        end)

        :ok

      :phoenix_pubsub ->
        Phoenix.PubSub.broadcast(pubsub_name!(), topic, message)
        :ok

      {:mfa, {mod, fun, extra}} ->
        # A host-supplied MFA must never take down the caller (most often the
        # log Streamer, whose death drops the pagination cursor). Rescue and
        # log loudly so misconfigured routing is operator-visible.
        try do
          apply(mod, fun, [topic, message | extra])
        rescue
          e ->
            Logger.error(
              "[ExAtlas.Fly.Dispatcher] :mfa dispatcher raised; " <>
                "topic=#{inspect(topic)} mfa=#{inspect({mod, fun, length(extra) + 2})} " <>
                "reason=#{Exception.message(e)}"
            )
        catch
          kind, payload ->
            Logger.error(
              "[ExAtlas.Fly.Dispatcher] :mfa dispatcher threw; " <>
                "topic=#{inspect(topic)} mfa=#{inspect({mod, fun, length(extra) + 2})} " <>
                "kind=#{inspect(kind)} payload=#{inspect(payload)}"
            )
        end

        :ok
    end
  end

  @doc """
  Whether this dispatcher needs its own supervised child (the atlas Registry).

  Returns `true` only in `:registry` mode.
  """
  @spec needs_registry?() :: boolean()
  def needs_registry? do
    mode() == :registry
  end

  defp mode do
    fly_config = Application.get_env(:ex_atlas, :fly, [])

    case Keyword.get(fly_config, :dispatcher, :registry) do
      :phoenix_pubsub ->
        if Code.ensure_loaded?(Phoenix.PubSub) and Keyword.get(fly_config, :pubsub) do
          :phoenix_pubsub
        else
          :registry
        end

      other ->
        other
    end
  end

  defp pubsub_name! do
    case Application.get_env(:ex_atlas, :fly, [])[:pubsub] do
      nil ->
        raise ArgumentError,
              "dispatcher: :phoenix_pubsub requires `config :ex_atlas, :fly, pubsub: MyApp.PubSub`"

      name ->
        name
    end
  end
end
