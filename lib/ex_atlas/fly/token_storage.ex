defmodule ExAtlas.Fly.TokenStorage do
  @moduledoc """
  Behaviour for durable Fly token storage.

  `ExAtlas.Fly.Tokens.Server` uses a `TokenStorage` implementation to persist
  tokens across VM restarts. The default implementation is
  `ExAtlas.Fly.TokenStorage.Dets`, a zero-config DETS-backed table. Hosts can
  swap in their own implementation (e.g. a DB-backed adapter) by setting
  `config :ex_atlas, :fly, token_storage: MyApp.FlyTokenStorage`.

  ## Keys

    * `:cached` — a regular, expiring token acquired via the CLI or `~/.fly/config.yml`.
      Stored with `expires_at` (unix seconds).
    * `:manual` — a user-provided override used as a last-resort fallback.
      Stored without an expiry (`expires_at: nil`).

  Implementations must also return a `child_spec/1` so the atlas supervisor
  tree can start them.
  """

  @type app_name :: String.t()
  @type key :: :cached | :manual
  @type token_record :: %{
          required(:token) => String.t(),
          required(:expires_at) => integer() | nil
        }

  @callback get(app_name(), key()) :: {:ok, token_record()} | :error
  @callback put(app_name(), key(), token_record()) :: :ok
  @callback delete(app_name(), key()) :: :ok
  @callback child_spec(keyword()) :: Supervisor.child_spec()
end
