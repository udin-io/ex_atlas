# ADR: CLI Detection UI in Provider Form

## Status
Accepted

## Context
The provider form currently requires manual token entry for all providers. For Fly.io, users often already have a valid token stored locally via the `flyctl` CLI tool. The previous sub-tickets (1-3) implemented `CliDetector`, `TokenCache`, and `Fly.Client` 401 retry support. This sub-ticket needs to expose CLI detection in the UI.

Key decisions: where to place the UI, how to handle org auto-detection (Fly Machines API lacks an orgs endpoint — only available via GraphQL), and whether detection should be synchronous or async.

## Decision
1. **Synchronous detection in LiveView event handler** — `CliDetector.detect/0` reads an env var and a small YAML file, both sub-millisecond operations. No async task needed.
2. **Conditional UI** — "Detect from CLI" button only appears when provider type is "fly" and action is `:new`. Not shown for edit (already has token) or other providers.
3. **GraphQL for org listing** — Add a minimal `list_orgs/1` to `Fly.Client` that posts a single query to `https://api.fly.io/graphql`. This avoids adding a full GraphQL client dependency.
4. **Org selection via clickable badges** — After fetching orgs, display them as DaisyUI badges the user can click to fill the org_slug field.
5. **Form update via AshPhoenix.Form.validate** — Pre-fill detected token by passing updated params through the existing form validation pipeline, keeping form state consistent.

## Consequences
- **Positive**: Reduces friction for Fly.io setup from ~5 steps (find token, copy, paste, find org, type) to 2 clicks
- **Positive**: No new dependencies — uses existing `Req` for the GraphQL call
- **Positive**: Graceful degradation — if CLI detection fails, manual entry still works
- **Negative**: GraphQL org listing adds a second API surface (Machines REST + GraphQL) to maintain
- **Negative**: CLI detection only works in dev/local where flyctl is installed — not useful in production server context