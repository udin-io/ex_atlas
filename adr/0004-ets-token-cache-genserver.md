# ADR: ETS Token Cache GenServer

## Status
Accepted

## Context
Every Fly.io API call triggers AshCloak decryption from the database via `credential.api_token`. During sync cycles with dozens of API calls per credential, this means repeated DB reads and decryption. The CLI token detection also needs caching so `detect/0` isn't called per request.

## Decision
1. Single global GenServer owns a protected ETS table `:fly_tokens`.
2. Protected ETS — only owner writes; any process reads. Reads bypass GenServer; writes serialized through calls.
3. No automatic TTL — explicit invalidation via `invalidate/1`. Fly.io tokens don't expire; 401 retry handles stale tokens.
4. Lazy population — cached on first access, not pre-loaded.
5. `:not_found` and errors NOT cached — only successful fetches stored.
6. Configurable name/table for test isolation.

## Consequences

### Positive
- ETS lookup <1us vs DB+decryption per call
- Protected table prevents accidental writes
- Simple invalidation API for 401 retry integration
- GenServer crash restarts with empty cache (self-healing)

### Negative
- Decrypted tokens in memory — acceptable tradeoff
- No automatic cleanup for deleted credentials — stale entries harmless
- Single GenServer write bottleneck — mitigated by reads bypassing GenServer
