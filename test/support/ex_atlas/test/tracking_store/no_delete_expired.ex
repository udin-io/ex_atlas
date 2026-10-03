defmodule ExAtlas.Test.TrackingStore.NoDeleteExpired do
  @moduledoc """
  `ExAtlas.Orchestrator.TrackingStore.Ecto` without `delete_expired/3`: a
  custom store written before issue 145.
  """

  @behaviour ExAtlas.Orchestrator.TrackingStore

  alias ExAtlas.Orchestrator.TrackingStore.Ecto, as: Store

  @impl true
  defdelegate child_spec(opts), to: Store
  @impl true
  defdelegate put(record), to: Store
  @impl true
  defdelegate get(id), to: Store
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
end
