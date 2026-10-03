defmodule ExAtlas.Test.TrackingStore.Hooked do
  @moduledoc """
  `ExAtlas.Orchestrator.TrackingStore.Ecto`, with a hook that runs just
  before `delete_expired/3` reaches it.

  `hook/1` sets a 0-arity function. It runs after the Reaper read the record
  and the dead owners, so a test can claim the record or renew the lease in
  between. It returns `:continue` to call the Ecto store, or `{:replace,
  answer}` to answer without it. It may raise, throw or exit. `hook_get/1`
  does the same for `get/1`.
  """

  @behaviour ExAtlas.Orchestrator.TrackingStore

  alias ExAtlas.Orchestrator.TrackingStore.Ecto, as: Store

  @key {__MODULE__, :hook}
  @get_key {__MODULE__, :get_hook}

  @doc "Run `fun` before each `delete_expired/3` call, until `clear/0`."
  def hook(fun) when is_function(fun, 0), do: :persistent_term.put(@key, fun)

  @doc "Run `fun` before each `get/1` call, until `clear/0`."
  def hook_get(fun) when is_function(fun, 0), do: :persistent_term.put(@get_key, fun)

  def clear do
    :persistent_term.erase(@key)
    :persistent_term.erase(@get_key)
  end

  @impl true
  defdelegate child_spec(opts), to: Store
  @impl true
  defdelegate put(record), to: Store
  @impl true
  def get(id) do
    case :persistent_term.get(@get_key, fn -> :continue end).() do
      :continue -> Store.get(id)
      {:replace, answer} -> answer
    end
  end

  @impl true
  defdelegate delete(id), to: Store
  @impl true
  defdelegate all(), to: Store
  @impl true
  defdelegate renew_lease(owner, at), to: Store
  @impl true
  defdelegate claim_expired(claimer, now, rewrite), to: Store
  @impl true
  defdelegate expired_leases(now), to: Store

  @impl true
  def delete_expired(id, owner, at) do
    case :persistent_term.get(@key, fn -> :continue end).() do
      :continue -> Store.delete_expired(id, owner, at)
      {:replace, answer} -> answer
    end
  end
end
