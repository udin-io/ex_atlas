defmodule Atlas.Providers.Vast do
  @moduledoc """
  Placeholder for the Vast.ai marketplace provider (planned for Atlas v0.3).

  Vast.ai's bidding model stress-tests the `Atlas.Spec.ComputeRequest`
  abstraction more than per-hour-priced providers do.

  All callbacks currently return `{:error, %Atlas.Error{kind: :unsupported}}`.
  """

  use Atlas.Providers.Stub,
    provider: :vast,
    capabilities: [:spot, :raw_tcp],
    docs_url: "https://hexdocs.pm/atlas"
end
