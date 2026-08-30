import assert from "node:assert/strict"
import test from "node:test"
import {createHmac} from "node:crypto"
import {CompositeTokenVerifier} from "../src/auth.js"

const bearer = (claims: object, secret: string) => {
  const payload = Buffer.from(JSON.stringify(claims)).toString("base64url")
  const signature = createHmac("sha256", secret).update(payload).digest("base64url")
  return `ags_${payload}.${signature}`
}

test("scoped agent bearer credentials validate locally without OIDC discovery", async () => {
  process.env.AGENT_BEARER_SECRET = "agent-bearer-test-secret"
  const humanId = "5f1bf56f-8de9-420e-bff6-3027f2648a68"
  const token = bearer({
    sub: humanId,
    scopes: ["profile:read", "feed:read"],
    iat: 1,
    exp: Math.floor(Date.now() / 1000) + 60,
    jti: "test-jti",
  }, process.env.AGENT_BEARER_SECRET)

  const auth = await new CompositeTokenVerifier().verifyAccessToken(token)
  assert.equal(auth.extra?.humanId, humanId)
  assert.deepEqual(auth.scopes, ["profile:read", "feed:read"])
})

test("tampered agent bearer credentials are rejected", async () => {
  process.env.AGENT_BEARER_SECRET = "agent-bearer-test-secret"
  const token = bearer({
    sub: "5f1bf56f-8de9-420e-bff6-3027f2648a68",
    scopes: ["profile:read"],
    iat: 1,
    exp: Math.floor(Date.now() / 1000) + 60,
    jti: "test-jti",
  }, process.env.AGENT_BEARER_SECRET)

  await assert.rejects(
    () => new CompositeTokenVerifier().verifyAccessToken(`${token.slice(0, -1)}x`),
    /signature/,
  )
})
