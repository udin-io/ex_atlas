defmodule ExAtlas.Fly.Tokens do
  @moduledoc """
  Thin facade over `ExAtlas.Fly.Tokens.Server`.

  See the server module for the full resolution chain and caching semantics.
  """

  alias ExAtlas.Fly.Tokens.Server

  @doc """
  Returns a token for `app_name`, acquiring it if necessary.

  Resolution order: ETS → `ExAtlas.Fly.TokenStorage` (durable) →
  `~/.fly/config.yml` → `fly tokens create readonly` CLI → manual override.
  """
  @spec get(String.t()) :: {:ok, String.t()} | {:error, :no_token_available}
  defdelegate get(app_name), to: Server, as: :get_token

  @doc "Invalidate the ETS cache entry for `app_name`, forcing re-acquisition."
  @spec invalidate(String.t()) :: :ok
  defdelegate invalidate(app_name), to: Server, as: :invalidate_token

  @doc """
  Store a manual override token for `app_name` (used as a last-resort fallback).

  Returns `{:error, {:persist_failed, reason}}` if the underlying storage fails —
  manual tokens are not re-acquirable, so the failure is surfaced rather than logged.
  """
  @spec set_manual(String.t(), String.t()) ::
          :ok | {:error, {:persist_failed, String.t()}}
  defdelegate set_manual(app_name, token), to: Server, as: :set_manual_token
end
