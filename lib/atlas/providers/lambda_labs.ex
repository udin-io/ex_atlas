defmodule Atlas.Providers.LambdaLabs do
  @moduledoc """
  Placeholder for the Lambda Labs Cloud GPU provider (planned for Atlas v0.2).

  Lambda Labs is a strong second reference for on-demand per-hour GPU rentals —
  validating the `Atlas.Provider` abstraction against a second real backend.

  All callbacks currently return `{:error, %Atlas.Error{kind: :unsupported}}`.
  """

  use Atlas.Providers.Stub,
    provider: :lambda_labs,
    capabilities: [:raw_tcp],
    docs_url: "https://hexdocs.pm/atlas"
end
