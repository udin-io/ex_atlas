# ADR: Fly CLI Token Detector

## Status
Accepted

## Context
Every Fly.io API call requires a token from a DB-stored `Credential`. For local development, `flyctl` already stores tokens in `~/.fly/config.yml` and the `FLY_ACCESS_TOKEN` env var. Developers must manually copy-paste tokens, which is friction-heavy.

`yaml_elixir` (v2.12.1) is already a transitive dependency via `reactor`. We need it as a direct dependency since we're using it explicitly.

The config file format uses an `access_token` key at the top level of the YAML document.

## Decision
1. Create a standalone `Atlas.Providers.Adapters.Fly.CliDetector` module with a single public function `detect/1`.
2. Resolution order: `FLY_ACCESS_TOKEN` env var → `~/.fly/config.yml` → `:not_found`.
3. Accept a `:config_path` option for testability — avoids mocking the filesystem.
4. Add `yaml_elixir` as an explicit dependency (already transitive via reactor).
5. Handle all error cases gracefully: missing file, malformed YAML, missing key, empty token — all return `:not_found`.
6. No logging of token values for security.

## Consequences
- **Positive**: Eliminates token copy-paste friction for local dev. Clean, testable module with no side effects. Foundation for sub-tickets 2-4 (caching, retry, UI).
- **Positive**: `config_path` injection makes tests fast and deterministic without mocks.
- **Negative**: Adding yaml_elixir as explicit dep increases surface area slightly (already present transitively).
- **Risk**: Fly.io could change config file format — mitigated by graceful fallback to `:not_found`.