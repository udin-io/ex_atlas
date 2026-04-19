# Changelog

## v0.1.0 — unreleased

Initial release. Highlights:

- `Atlas.Provider` behaviour + normalized `Atlas.Spec.*` structs.
- Full RunPod provider (REST management, serverless runtime, legacy GraphQL
  catalog) built on `Req`.
- In-memory `Atlas.Providers.Mock` for tests and demos.
- Placeholder `Atlas.Providers.Fly`, `Atlas.Providers.LambdaLabs`, and
  `Atlas.Providers.Vast` reserving names and capability lists for the v0.2
  and v0.3 releases.
- `Atlas.Auth.Token` and `Atlas.Auth.SignedUrl` for the per-user preshared-key
  pattern.
- Opt-in orchestrator: `Atlas.Orchestrator.ComputeServer` (GenServer per
  resource), `Reaper` (reconciles orphans, enforces idle TTL), and
  `Phoenix.PubSub` broadcasts.
- Telemetry events `[:atlas, <provider>, :request]`.
- Shared `Atlas.Test.ProviderConformance` suite every provider must pass.
