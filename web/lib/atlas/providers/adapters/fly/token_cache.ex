defmodule Atlas.Providers.Adapters.Fly.TokenCache do
  @moduledoc """
  GenServer owning a protected ETS table that caches decrypted Fly.io tokens.

  Eliminates repeated AshCloak decryption during sync cycles.
  Tokens are cached until explicitly invalidated (no TTL).
  Only successful fetches are cached; `:not_found` and errors are not stored.

  ## Cache keys

    * `:cli` - CLI-detected token (from env var or config file)
    * `credential_id` (UUID string) - credential API token from database
  """

  use GenServer

  alias Atlas.Providers.Adapters.Fly.CliDetector
  alias Atlas.Providers.Credential

  @default_name __MODULE__
  @default_table :fly_tokens

  # Client API

  @doc "Starts the TokenCache GenServer."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    table_name = Keyword.get(opts, :table_name, @default_table)
    cli_detector_opts = Keyword.get(opts, :cli_detector_opts, [])

    GenServer.start_link(
      __MODULE__,
      %{table_name: table_name, name: name, cli_detector_opts: cli_detector_opts},
      name: name
    )
  end

  @doc "Returns the cached CLI token, fetching via CliDetector on miss."
  @spec get_cli_token(GenServer.server()) :: {:ok, String.t()} | :not_found
  def get_cli_token(server \\ @default_name) do
    case ets_lookup(server, :cli) do
      {:ok, token} -> {:ok, token}
      :miss -> GenServer.call(server, :fetch_cli_token)
    end
  end

  @doc "Returns the cached credential token, fetching from DB on miss."
  @spec get_token(String.t(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def get_token(credential_id, server \\ @default_name) do
    case ets_lookup(server, credential_id) do
      {:ok, token} -> {:ok, token}
      :miss -> GenServer.call(server, {:fetch_token, credential_id})
    end
  end

  @doc "Invalidates a cached token entry."
  @spec invalidate(term(), GenServer.server()) :: :ok
  def invalidate(key, server \\ @default_name) do
    GenServer.call(server, {:invalidate, key})
  end

  # Server callbacks

  @impl true
  def init(%{table_name: table_name, name: name, cli_detector_opts: cli_detector_opts}) do
    table = :ets.new(table_name, [:set, :protected, :named_table])
    :persistent_term.put({__MODULE__, name}, table_name)
    {:ok, %{table: table, cli_detector_opts: cli_detector_opts}}
  end

  @impl true
  def handle_call(:fetch_cli_token, _from, %{table: table, cli_detector_opts: cli_opts} = state) do
    # Double-check: another process may have populated cache while we waited
    result =
      case :ets.lookup(table, :cli) do
        [{:cli, token}] ->
          {:ok, token}

        [] ->
          case CliDetector.detect(cli_opts) do
            {:ok, token} ->
              :ets.insert(table, {:cli, token})
              {:ok, token}

            :not_found ->
              :not_found
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:fetch_token, credential_id}, _from, %{table: table} = state) do
    result =
      case :ets.lookup(table, credential_id) do
        [{^credential_id, token}] ->
          {:ok, token}

        [] ->
          case Credential.get_by_id(credential_id, authorize?: false) do
            {:ok, credential} ->
              token = credential.api_token
              :ets.insert(table, {credential_id, token})
              {:ok, token}

            {:error, _} = error ->
              error
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:invalidate, key}, _from, %{table: table} = state) do
    :ets.delete(table, key)
    {:reply, :ok, state}
  end

  # Private helpers

  defp ets_lookup(server, key) do
    table_name = :persistent_term.get({__MODULE__, server})

    case :ets.lookup(table_name, key) do
      [{^key, token}] -> {:ok, token}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end
end
