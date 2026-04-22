defmodule ExAtlas.Providers.Vast do
  @moduledoc """
  Placeholder for the Vast.ai marketplace provider (planned for ExAtlas v0.3).

  Vast.ai's bidding model stress-tests the `ExAtlas.Spec.ComputeRequest`
  abstraction more than per-hour-priced providers do.

  All callbacks currently return `{:error, %ExAtlas.Error{kind: :unsupported}}`.
  """

  use ExAtlas.Providers.Stub,
    provider: :vast,
    capabilities: [:spot, :raw_tcp],
    docs_url: "https://hexdocs.pm/atlas"
end
