import assert from "node:assert/strict"
import test from "node:test"

const {buildPostPayload, normalizeDraftInput} = await import(`../js/collab_studio.js?test=${Date.now()}`)

test("agent drafts are normalized into bounded public post fields", () => {
  const draft = normalizeDraftInput({
    summary: "  People thinking about slower, better networks  ",
    body: "  I keep wondering what happens when connection starts with fragments.  ",
    relationship_modes: ["friendship", "friendship", "unknown"],
    topic_ids: ["webmcp", "social-agents", "webmcp"],
    agent_note: "  Kept the question open.  ",
  })

  assert.deepEqual(draft.relationship_modes, ["friendship"])
  assert.deepEqual(draft.topic_ids, ["webmcp", "social-agents"])
  assert.equal(draft.summary, "People thinking about slower, better networks")
  assert.equal(draft.agent_note, "Kept the question open.")

  const payload = buildPostPayload(draft, "studio-post-001")
  assert.equal(payload.visibility, "public")
  assert.equal(payload.format, "text/plain")
  assert.equal(payload.rankable_metadata.collaboration_surface, "shared_draft")
  assert.equal(payload.idempotency_key, "studio-post-001")
  assert.equal(payload.opaque_payload, draft.body)
})

test("agent drafts require a body, summary, and supported relationship mode", () => {
  assert.throws(
    () => normalizeDraftInput({summary: "Summary", body: "", relationship_modes: ["friendship"]}),
    /draft_body_required/,
  )
  assert.throws(
    () => normalizeDraftInput({summary: "", body: "Body", relationship_modes: ["friendship"]}),
    /draft_summary_required/,
  )
  assert.throws(
    () => normalizeDraftInput({summary: "Summary", body: "Body", relationship_modes: ["romance"]}),
    /relationship_mode_required/,
  )
})
