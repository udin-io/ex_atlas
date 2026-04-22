defmodule ExAtlas.Providers.Fly do
  @moduledoc """
  Placeholder for the Fly.io Machines provider (planned for ExAtlas v0.2).

  Fly.io Machines fits naturally alongside RunPod for this library's core use
  case: a Fly.io-hosted Phoenix app can spawn GPU Machines in the same region
  as itself for minimal-latency inference, using the ExAtlas API surface.

  All callbacks currently return `{:error, %ExAtlas.Error{kind: :unsupported}}`.
  """

  use ExAtlas.Providers.Stub,
    provider: :fly,
    capabilities: [:http_proxy, :raw_tcp, :global_networking],
    docs_url: "https://hexdocs.pm/atlas"
end
