# ADR: Seed Data Admin User Confirmation

## Status

Accepted

## Context

The Atlas application uses AshAuthentication with email confirmation enabled (`confirm_on_create? true`, `require_interaction? true`). The seed script creates an admin user via the `register_with_password` action, but this triggers the confirmation flow requiring the user to click an email link before they can sign in. In development, there is no real email delivery, making it impossible to confirm the seeded admin user through normal means.

Additionally, the seed script runs outside any authenticated context, but the User resource has `Ash.Policy.Authorizer` enabled with only an `AshAuthenticationInteraction` bypass. Seed operations need explicit `authorize?: false` to reliably bypass policy checks.

## Decision

1. **Force-set `confirmed_at`** on the seeded admin user immediately after creation using `Ash.Changeset.force_change_attribute/3`. This bypasses the normal confirmation flow, which is appropriate for seed data.

2. **Pass `authorize?: false`** to all Ash operations in the seed script to ensure they run regardless of policy configuration.

3. **Add a test** for the seed script verifying both user creation with confirmation and idempotency.

## Consequences

### Positive
- Admin user can sign in immediately after running seeds in development
- Seed script is robust against policy changes
- Test coverage ensures seed script stays functional as the User resource evolves

### Negative
- The seed script bypasses normal security flows (acceptable for dev seed data)
- If the User resource schema changes (e.g., `confirmed_at` is renamed or removed), the seed script will need updating — the test will catch this
