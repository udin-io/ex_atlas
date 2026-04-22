defmodule ExAtlas.Fly.Tokens.Registry do
  @moduledoc """
  `Registry` process that `ExAtlas.Fly.Tokens.Supervisor` starts under the
  Fly sub-tree.

  Keys are `:unique` and hold a single `AppServer` pid per Fly app.

  ## Key shape

      app_name :: String.t()

  The registry is started by `ExAtlas.Fly.Tokens.Supervisor`; this module is
  documentation-only and exists so the registry name has a canonical home.
  """
end
