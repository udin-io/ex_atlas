# ADR: Atlas Port Environment Variable

## Status

Accepted

## Context

Atlas is an SRE/DevOps tool managed by udincode, which orchestrates multiple services. The generic `PORT` environment variable used by Phoenix can conflict when udincode needs to start Atlas alongside other services on specific ports. A dedicated environment variable is needed to give udincode explicit control over Atlas's port.

## Decision

1. Support an `ATLAS_PORT` environment variable that takes highest precedence for configuring the HTTP port.
2. Fall back to the standard `PORT` environment variable if `ATLAS_PORT` is not set, maintaining compatibility with Fly.io and other PaaS platforms.
3. Default to port `4000` if neither variable is set, preserving current behavior.

The precedence order is: `ATLAS_PORT` > `PORT` > `4000`.

## Consequences

- **Positive**: udincode can start Atlas on any port without affecting other services that also use `PORT`.
- **Positive**: Backward compatible — existing deployments using `PORT` continue to work unchanged.
- **Positive**: Fly.io deployments are unaffected since they set `PORT` which remains supported.
- **Negative**: One more env var to document, though it follows a clear naming convention.
