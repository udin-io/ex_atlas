defmodule ExAtlas.Providers.LambdaLabs do
  @moduledoc """
  Placeholder for the Lambda Labs Cloud GPU provider (planned for ExAtlas v0.2).

  Lambda Labs is a strong second reference for on-demand per-hour GPU rentals —
  validating the `ExAtlas.Provider` abstraction against a second real backend.

  All callbacks currently return `{:error, %ExAtlas.Error{kind: :unsupported}}`.
  """

  use ExAtlas.Providers.Stub,
    provider: :lambda_labs,
    capabilities: [:raw_tcp],
    docs_url: "https://hexdocs.pm/atlas"
end
