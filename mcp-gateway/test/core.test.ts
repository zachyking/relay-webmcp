import assert from "node:assert/strict"
import test from "node:test"
import {createHmac} from "node:crypto"
import {coreRequest, signedHeaders} from "../src/core.js"

test("service signature binds identity, scopes, client, method, and path", () => {
  process.env.MCP_INTERNAL_SECRET = "test-secret"
  const auth = {
    token: "not-forwarded",
    clientId: "codex-client",
    scopes: ["feed:read", "profile:read"],
    extra: {subject: "oidc-user-1"},
  }

  const headers = signedHeaders(auth, "GET", "/api/v1/feed", "1000", "nonce-1234567890", "")
  const input = "1000:nonce-1234567890:oidc_sub:oidc-user-1:feed:read profile:read:codex-client::GET:/api/v1/feed"
  const expected = createHmac("sha256", "test-secret").update(input).digest("base64url")

  assert.equal(headers["x-agent-signature"], expected)
  assert.equal(headers["x-agent-oidc-sub"], "oidc-user-1")
  assert.equal(headers["x-agent-nonce"], "nonce-1234567890")
  assert.equal(headers.authorization, undefined)
})

test("service signature supports a locally verified human identity", () => {
  process.env.MCP_INTERNAL_SECRET = "test-secret"
  const auth = {
    token: "not-forwarded",
    clientId: "scoped-agent-bearer",
    scopes: ["profile:read"],
    extra: {humanId: "ee3bfe64-e34c-4c21-88e8-4f86f5a1b349"},
  }

  const headers = signedHeaders(auth, "GET", "/api/v1/profiles/me", "1000", "nonce-abcdefghijk", "")
  assert.equal(headers["x-agent-human-id"], auth.extra.humanId)
  assert.equal(headers["x-agent-oidc-sub"], undefined)
})

test("core requests preserve caller idempotency while stripping it from domain input", async () => {
  process.env.MCP_INTERNAL_SECRET = "test-secret"
  const originalFetch = globalThis.fetch
  let captured: {headers?: HeadersInit; body?: BodyInit | null} = {}

  globalThis.fetch = async (_input, init) => {
    captured = {headers: init?.headers, body: init?.body}
    return new Response(JSON.stringify({data: {ok: true}}), {
      status: 200,
      headers: {"content-type": "application/json"},
    })
  }

  try {
    await coreRequest({
      token: "not-forwarded",
      clientId: "test-client",
      scopes: ["profile:write"],
      extra: {humanId: "ee3bfe64-e34c-4c21-88e8-4f86f5a1b349"},
    }, "PUT", "/api/v1/profiles/me/claims", {
      idempotency_key: "stable-command-001",
      key: "availability",
    })

    assert.equal((captured.headers as Record<string, string>)["idempotency-key"], "stable-command-001")
    assert.equal((captured.headers as Record<string, string>)["x-forwarded-proto"], "https")
    assert.deepEqual(JSON.parse(String(captured.body)), {key: "availability"})
  } finally {
    globalThis.fetch = originalFetch
  }
})
