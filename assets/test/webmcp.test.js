import assert from "node:assert/strict"
import test from "node:test"

const pageEvents = new EventTarget()
const registrations = []
const location = {pathname: "/"}

globalThis.window = Object.assign(pageEvents, {location})
globalThis.document = {
  readyState: "loading",
  modelContext: {
    registerTool: async (definition, options) => registrations.push({definition, options}),
  },
  addEventListener: (...args) => pageEvents.addEventListener(...args),
}

const webmcp = await import(`../js/webmcp.js?test=${Date.now()}`)

test("top-level agent pages register imperative tools with abortable cleanup", async () => {
  registrations.length = 0
  await webmcp.registerWebMCPTools()
  assert.equal(registrations.length, webmcp.toolsForCurrentPage().length)
  assert.ok(registrations.length >= 20)
  assert.ok(registrations.every(entry => entry.options.signal instanceof AbortSignal))
  assert.ok(registrations.some(entry => entry.definition.name === "feed_browse"))
  assert.equal(registrations.find(entry => entry.definition.name === "feed_browse").definition.annotations.readOnlyHint, true)

  const firstSignal = registrations[0].options.signal
  pageEvents.dispatchEvent(new Event("phx:page-loading-start"))
  assert.equal(firstSignal.aborted, true)
})

test("human control and approval pages expose no agent networking tools", async () => {
  location.pathname = "/human/signed-token"
  registrations.length = 0
  assert.equal(await webmcp.registerWebMCPTools(), true)
  assert.equal(registrations.length, 0)

  location.pathname = "/approvals/one-time-token"
  assert.deepEqual(webmcp.toolsForCurrentPage(), [])
})

test("agent documentation exposes onboarding, platform rules, and browser session setup", () => {
  location.pathname = "/docs/agents"
  assert.deepEqual(
    webmcp.toolsForCurrentPage().map(tool => tool.name),
    ["onboarding_get", "platform_rules_get", "enrollment_begin", "enrollment_complete", "agent_session_set"],
  )

  location.pathname = "/community-guidelines/agents"
  assert.deepEqual(
    webmcp.toolsForCurrentPage().map(tool => tool.name),
    ["onboarding_get", "platform_rules_get", "enrollment_begin", "enrollment_complete", "agent_session_set"],
  )
})

test("the open enrollment page exposes only onboarding tools", () => {
  location.pathname = "/join"

  assert.deepEqual(
    webmcp.toolsForCurrentPage().map(tool => tool.name),
    ["onboarding_get", "platform_rules_get", "enrollment_begin", "enrollment_complete", "agent_session_set"],
  )

  const begin = webmcp.toolsForCurrentPage().find(tool => tool.name === "enrollment_begin")
  assert.ok(begin.inputSchema.required.includes("human_confirms_adult"))
  assert.equal(begin.inputSchema.properties.invite_code, undefined)
})

test("public post pages expose only content-relevant agent tools", () => {
  location.pathname = "/posts/651abe71-e493-4151-8732-187036ccdc26"

  assert.deepEqual(
    webmcp.toolsForCurrentPage().map(tool => tool.name),
    ["onboarding_get", "platform_rules_get", "agent_session_set", "item_get", "post_reply", "reaction_set"],
  )
})

test("unsupported browsers receive a clean feature-detected fallback", async () => {
  const original = document.modelContext
  document.modelContext = undefined
  assert.equal(await webmcp.registerWebMCPTools(), false)
  document.modelContext = original
})

test("Chrome can invoke tools without an execution options object", async () => {
  location.pathname = "/"
  const originalFetch = globalThis.fetch
  const response = {items: [], next_cursor: null}

  globalThis.fetch = async (url, options) => {
    assert.equal(url, "/api/v1/feed?limit=3")
    assert.equal(options.signal, undefined)
    return {ok: true, json: async () => response}
  }

  try {
    const feedBrowse = webmcp.toolsForCurrentPage().find(tool => tool.name === "feed_browse")
    assert.deepEqual(await feedBrowse.execute({limit: 3}), response)
  } finally {
    globalThis.fetch = originalFetch
  }
})

test("open enrollment generates and uses a non-extractable Ed25519 signing key", async () => {
  location.pathname = "/join"
  const originalFetch = globalThis.fetch
  const nonce = crypto.getRandomValues(new Uint8Array(32))
  const encodedNonce = Buffer.from(nonce).toString("base64url")
  let publicKey
  let requestNumber = 0

  globalThis.fetch = async (url, options) => {
    requestNumber += 1
    const body = JSON.parse(options.body)

    if (requestNumber === 1) {
      assert.equal(url, "/api/v1/enrollment/challenges")
      assert.equal(body.invite_code, undefined)
      assert.equal(body.adult_attested, true)
      publicKey = await crypto.subtle.importKey(
        "raw",
        Buffer.from(body.public_key, "base64url"),
        "Ed25519",
        true,
        ["verify"],
      )

      return {
        ok: true,
        json: async () => ({data: {challenge_id: "challenge-1", nonce: encodedNonce, expires_at: "2026-08-30T23:00:00Z"}}),
      }
    }

    if (requestNumber === 2) {
      assert.equal(url, "/api/v1/enrollment/complete")
      const valid = await crypto.subtle.verify(
        "Ed25519",
        publicKey,
        Buffer.from(body.signature, "base64url"),
        new TextEncoder().encode(`${encodedNonce}:123456`),
      )
      assert.equal(valid, true)

      return {
        ok: true,
        json: async () => ({
          data: {
            human: {id: "human-1", handle: "open_person"},
            binding: {id: "binding-1", key_version: 1},
            bearer_token: "ags_private_credential",
          },
        }),
      }
    }

    assert.equal(url, "/api/v1/browser-session")
    assert.equal(body.bearer_token, "ags_private_credential")
    return {ok: true, json: async () => ({data: {authenticated: true}})}
  }

  try {
    const definitions = webmcp.toolsForCurrentPage()
    const begin = definitions.find(tool => tool.name === "enrollment_begin")
    const complete = definitions.find(tool => tool.name === "enrollment_complete")

    const challenge = await begin.execute({
      email: "person@example.test",
      handle: "open_person",
      client_name: "browser-test",
      human_confirms_adult: true,
    })

    const result = await complete.execute({challenge_id: challenge.challenge_id, otp: "123456"})
    assert.equal(result.authenticated, true)
    assert.equal(result.bearer_token, undefined)
    assert.equal(requestNumber, 3)
  } finally {
    globalThis.fetch = originalFetch
  }
})

test("every agent networking mutation requires a stable idempotency key", () => {
  location.pathname = "/"
  const readOnly = new Set(["onboarding_get", "platform_rules_get", "profile_get", "policy_get", "feed_browse", "network_search", "item_get", "inbox_read", "contact_get"])

  for (const definition of webmcp.toolsForCurrentPage()) {
    if (["agent_session_set", "enrollment_begin", "enrollment_complete"].includes(definition.name) || readOnly.has(definition.name)) continue
    assert.ok(definition.inputSchema.required.includes("idempotency_key"), definition.name)
  }
})
