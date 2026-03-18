defmodule Atlas.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Atlas.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:atlas, :token_signing_secret)
  end
end
