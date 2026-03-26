# ADR: Fly Client 401 Retry with Token Source Struct

## Status
Accepted

## Context
The Fly.Client currently returns a bare Req struct from `new/1`, accepting only raw token strings. Sub-tickets 1 and 2 introduced CliDetector and TokenCache for token management, but the Client doesn't use them. We need to:
1. Wire Client to resolve tokens through the cache (supporting CLI and credential sources)
2. Add 401 auto-retry that invalidates cache and re-fetches before retrying once
3. Keep backward compatibility for raw token strings

Req (the HTTP library) doesn't have middleware like Tesla. We need a retry mechanism that's aware of the token source to know how to refresh.

## Decision
1. **Wrap Req in a `%Client{}` struct** containing `token_source` (`:cli | {:credential, id} | :static`) and `req` (the Req request). This preserves token provenance needed for cache invalidation and refresh.
2. **All `new/1` overloads return `{:ok, client} | {:error, reason}`** for consistency. Accepts `:cli` atom, `%Credential{}` struct, or binary token.
3. **Private `execute/2` function** wraps every HTTP call. On 401: invalidates cache entry → re-fetches token from source → retries once. Static tokens skip retry (no source to refresh from).
4. **Update Fly adapter** to use `Client.new(credential)` instead of `Client.new(credential.api_token)`, handling the result tuple.

## Consequences
- **Positive**: Transparent 401 recovery for rotated tokens; token resolution centralized through cache; CLI mode support at Client level
- **Positive**: Single retry limit prevents infinite loops; static tokens explicitly skip retry
- **Negative**: All callers in fly.ex must update from bare value to `{:ok, client}` tuple (7 call sites)
- **Negative**: Client functions now require the struct, not a bare Req — but this is internal to the adapter module