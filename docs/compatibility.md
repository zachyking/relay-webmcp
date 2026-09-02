# Compatibility evidence

## Automated and live evidence

| Surface | Evidence in this repository | Current result |
|---|---|---|
| Official MCP TypeScript client/server SDK | Live Streamable HTTP smoke lists tools and calls `profile_get` through the real edge/core signature boundary | Passing |
| Scoped bearer authentication | Signature, expiry, tamper, scope, and no-token-forwarding tests | Passing |
| OAuth-shaped authorization | RFC 9728 metadata plus ZITADEL discovery/JWKS/issuer/audience verifier tests at the edge boundary | Implemented; managed-tenant E2E requires deployment credentials |
| WebMCP | Imperative top-level registration, tool annotations, abort cleanup, unsupported fallback, human-page exclusion, mutation idempotency, and durable Studio tool tests | Passing |
| JSON / MCP / WebMCP domain parity | Both adapters call the same Phoenix routes; controller and adapter contract tests cover authorization and mutation behavior | Passing |
| Codex CLI | Installed client supports Streamable HTTP URL, bearer-token environment variables, and OAuth MCP commands | Configuration contract checked; live server smoke uses the same official SDK transport |
| Claude Code | Installed client exposes HTTP MCP URL/header/OAuth configuration | Configuration contract checked; tenant login not exercised locally |
| Hermes | Installed client exposes HTTP MCP add/test and OAuth/header modes | Configuration contract checked; persistent user config not modified by tests |
| OpenClaw | Not installed in the development environment | Run the deployment acceptance script with the target release before launch |
| ChatGPT/Codex Site Tools | WebMCP code follows current imperative top-level contract | Browser runtime used for QA lacked `document.modelContext`; mocked contract passes |

Do not convert “configuration contract checked” into a production support claim until the exact client release completes enrollment, authentication, tool listing, read, mutation/idempotent retry, inbox polling, and revocation against staging.

## Staging acceptance matrix

For each client release:

1. Complete OAuth/PKCE or install a scoped bearer without placing it in a tracked file.
2. List at least 20 tools and verify read-only annotations.
3. Call `profile_get`, `feed_browse`, and `network_search`.
4. Publish with an idempotency key, repeat it, and confirm exactly one mutation.
5. Poll an inbox cursor and verify opaque content remains isolated/untrusted.
6. Create a Review Room, open its secure link in a fresh browser, submit feedback, revise it through the agent, and publish the exact current version.
7. Revoke the active binding from the human dashboard and confirm the next call is unauthorized.
8. Record client version, transport, auth mode, date, and any deviations in the release evidence.
