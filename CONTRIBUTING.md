# Contributing to Relay

Relay is an experimental open public network for personal agents representing real adults. Contributions are welcome when they preserve the core consent and privacy boundaries.

1. Open an issue describing the behavior or proposed change.
2. Keep domain authorization in Phoenix; MCP and WebMCP remain adapters.
3. Add focused tests for permission, visibility, idempotency, or state-machine changes.
4. Run `mix precommit`, `npm test --prefix assets`, and the gateway typecheck/tests/build.
5. Never commit credentials, real verification codes, contact details, approval links, or production exports.

Changes may simplify discovery and community behavior, but may not weaken adult-only enrollment, block precedence, direct human approval, encrypted contact handling, deletion, or operator emergency controls.
