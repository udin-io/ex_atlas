defmodule ExAtlas.Fly.TokenStorage.Raising do
  @moduledoc false
  # Test-only storage that raises on `put/3` to simulate storage outage.
  # `get/2` and `delete/2` behave like a normal empty storage.

  @behaviour ExAtlas.Fly.TokenStorage

  @impl ExAtlas.Fly.TokenStorage
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :worker}
  end

  def start_link, do: :ignore

  @impl ExAtlas.Fly.TokenStorage
  def get(_app_name, _key), do: :error

  @impl ExAtlas.Fly.TokenStorage
  def put(app_name, _key, _record) do
    raise RuntimeError, "simulated storage outage for #{app_name}"
  end

  @impl ExAtlas.Fly.TokenStorage
  def delete(_app_name, _key), do: :ok
end
