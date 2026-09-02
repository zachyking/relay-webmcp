import assert from "node:assert/strict"
import test from "node:test"

const {
  buildPostPayload,
  configureStudioPersistence,
  configureStudioPublisher,
  configureStudioSessionProbe,
  initCollabStudio,
  markStudioFeedbackReady,
  normalizeDraftInput,
  publishStudioDraft,
  readStudioReview,
  setOverallFeedback,
  setParagraphFeedback,
  setStudioDraft,
} = await import(`../js/collab_studio.js?test=${Date.now()}`)

class FakeElement extends EventTarget {
  constructor(id = "") {
    super()
    this.id = id
    this.children = []
    this.dataset = {}
    this.disabled = false
    this.hidden = false
    this.href = ""
    this.textContent = ""
    this.value = ""
  }

  append(...children) {
    this.children.push(...children)
  }

  replaceChildren(...children) {
    this.children = children
  }

  setAttribute(name, value) {
    this[name] = value
  }
}

const installStudioDom = () => {
  configureStudioPersistence(undefined)
  configureStudioPublisher(undefined)
  configureStudioSessionProbe(undefined)
  const ids = [
    "collab-studio",
    "studio-agent-note",
    "studio-clear",
    "studio-draft-body",
    "studio-draft-content",
    "studio-draft-empty",
    "studio-draft-modes",
    "studio-draft-status",
    "studio-draft-summary",
    "studio-draft-topics",
    "studio-draft-updated",
    "studio-feedback-ready",
    "studio-overall-feedback",
    "studio-published-link",
    "studio-published-result",
    "studio-publish-button",
    "studio-publish-feedback",
    "studio-publish-label",
    "studio-review-content",
    "studio-review-empty",
    "studio-review-helper",
    "studio-review-sections",
    "studio-review-status",
    "studio-review-version",
    "studio-review-link",
    "studio-secure-link",
  ]
  const elements = new Map(ids.map(id => [id, new FakeElement(id)]))
  const storage = new Map()

  elements.get("collab-studio").dataset.draftVersion = "0"
  globalThis.document = {
    createElement: () => new FakeElement(),
    getElementById: id => elements.get(id) || null,
  }
  globalThis.window = {confirm: () => true}
  globalThis.location = {href: "http://localhost:4000/studio", hash: "", pathname: "/studio"}
  globalThis.history = {replaceState: (_state, _title, url) => { globalThis.location.href = url }}
  globalThis.sessionStorage = {
    getItem: key => storage.get(key) || null,
    removeItem: key => storage.delete(key),
    setItem: (key, value) => storage.set(key, value),
  }

  return elements
}

const firstDraft = () => ({
  summary: "A question about unfinished ideas",
  body: "What if we shared ideas before they were polished?\n\nThe rough edges might help the right people find us.",
  relationship_modes: ["friendship"],
  topic_ids: ["webmcp"],
  agent_note: "Started with the unresolved question.",
})

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
  assert.equal(payload.rankable_metadata.collaboration_surface, "shared_review_room")
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

test("the agent creates the first version and both panes render reviewable paragraphs", async () => {
  const elements = installStudioDom()
  initCollabStudio()

  const result = await setStudioDraft(firstDraft(), {mode: "create"})
  const review = await readStudioReview()

  assert.equal(result.draft_version, 1)
  assert.equal(result.review_url, "http://localhost:4000/studio")
  assert.equal(review.draft_visible, true)
  assert.equal(review.feedback_ready, false)
  assert.equal(review.paragraph_feedback.length, 2)
  assert.equal(elements.get("studio-review-sections").children.length, 2)
  assert.equal(elements.get("studio-draft-body").children.length, 2)
  assert.equal(elements.get("studio-review-empty").hidden, true)
  assert.equal(elements.get("studio-draft-status").textContent, "First draft")
  await assert.rejects(setStudioDraft(firstDraft(), {mode: "create"}), /draft_already_exists_use_revise/)
})

test("a created draft becomes a durable capability link and saves human review", async () => {
  const elements = installStudioDom()
  initCollabStudio()
  const reviewUrl = "http://localhost:4000/studio/review#rvw_secure-room-token-123456789012345678901234"
  let savedReview

  configureStudioPersistence({
    create: async draft => ({
      id: "room-1",
      draft,
      draft_version: 1,
      review: {draft_version: 1, overall_note: "", paragraph_feedback: {}, ready: false},
      review_url: reviewUrl,
      status: "review",
      published: null,
      expires_at: "2026-09-09T20:00:00Z",
      updated_at: "2026-09-02T20:00:00Z",
    }),
    saveReview: async (_token, review) => {
      savedReview = review
      return {
        id: "room-1",
        draft: firstDraft(),
        draft_version: 1,
        review: {...review, ready: false},
        status: "review",
        published: null,
        updated_at: "2026-09-02T20:01:00Z",
      }
    },
    markReady: async (_token, draftVersion) => ({
      id: "room-1",
      draft: firstDraft(),
      draft_version: draftVersion,
      review: {...savedReview, ready: true},
      status: "review",
      published: null,
      updated_at: "2026-09-02T20:02:00Z",
    }),
  })

  const result = await setStudioDraft(firstDraft(), {
    mode: "create",
    idempotencyKey: "durable-room-create-001",
  })

  assert.equal(result.review_url, reviewUrl)
  assert.equal(elements.get("collab-studio").dataset.sessionId, "room-1")
  assert.equal(elements.get("studio-review-link").textContent, reviewUrl)
  assert.equal(elements.get("studio-secure-link").hidden, false)

  setParagraphFeedback(1, {decision: "rewrite", comment: "End with a direct invitation."})
  const review = await markStudioFeedbackReady()

  assert.equal(savedReview.paragraph_feedback["1"].decision, "rewrite")
  assert.equal(review.feedback_ready, true)
})

test("human feedback is anchored to exact passages and explicitly marked ready", async () => {
  const elements = installStudioDom()
  initCollabStudio()
  await setStudioDraft(firstDraft(), {mode: "create"})

  setOverallFeedback("Keep it curious and end with an invitation.")
  setParagraphFeedback(0, {decision: "keep"})
  setParagraphFeedback(1, {decision: "rewrite", comment: "Make this less abstract."})
  assert.equal(elements.get("studio-feedback-ready").disabled, false)

  const review = await markStudioFeedbackReady()
  assert.equal(review.feedback_ready, true)
  assert.equal(review.overall_note, "Keep it curious and end with an invitation.")
  assert.equal(review.paragraph_feedback[0].decision, "keep")
  assert.equal(review.paragraph_feedback[1].decision, "rewrite")
  assert.equal(review.paragraph_feedback[1].comment, "Make this less abstract.")
  assert.equal(elements.get("studio-review-status").textContent, "Feedback ready")
})

test("switching a passage decision preserves its typed comment", async () => {
  const elements = installStudioDom()
  initCollabStudio()
  await setStudioDraft(firstDraft(), {mode: "create"})

  const secondCard = elements.get("studio-review-sections").children[1]
  const actions = secondCard.children[1]
  const comment = secondCard.children[2]
  const keepButton = actions.children[0]
  const rewriteButton = actions.children[2]

  rewriteButton.dispatchEvent(new Event("click"))
  comment.value = "Name the concrete product moment."
  comment.dispatchEvent(new Event("input"))
  keepButton.dispatchEvent(new Event("click"))

  const item = (await readStudioReview()).paragraph_feedback[1]
  assert.equal(item.decision, "keep")
  assert.equal(item.comment, "Name the concrete product moment.")
})

test("agent revisions require the exact reviewed version and reset stale feedback", async () => {
  installStudioDom()
  initCollabStudio()
  await setStudioDraft(firstDraft(), {mode: "create"})
  setParagraphFeedback(1, {decision: "cut", comment: "The first line is enough."})
  await markStudioFeedbackReady()

  await assert.rejects(
    setStudioDraft(firstDraft(), {mode: "revise", basedOnVersion: 0}),
    /stale_draft_version/,
  )

  const result = await setStudioDraft({
    ...firstDraft(),
    body: "What if we shared ideas before they were polished?",
    agent_note: "Cut the abstract second passage as requested.",
  }, {mode: "revise", basedOnVersion: 1})
  const review = await readStudioReview()

  assert.equal(result.draft_version, 2)
  assert.equal(review.draft_version, 2)
  assert.equal(review.feedback_ready, false)
  assert.equal(review.overall_note, "")
  assert.equal(review.paragraph_feedback.length, 1)
  assert.equal(review.paragraph_feedback[0].decision, "undecided")
})

test("the human publish button sends the exact visible draft", async () => {
  const elements = installStudioDom()
  let publishedDraft
  let publishKey

  configureStudioPublisher(async idempotencyKey => {
    publishedDraft = (await readStudioReview()).current_draft
    publishKey = idempotencyKey
    return {published: true, item_id: "post-1", public_url: "/posts/post-1"}
  })
  initCollabStudio()

  const {draft} = await setStudioDraft(firstDraft(), {mode: "create"})
  assert.equal(elements.get("studio-publish-button").disabled, false)

  elements.get("studio-publish-button").dispatchEvent(new Event("click"))
  await new Promise(resolve => setTimeout(resolve, 0))

  assert.deepEqual(publishedDraft, draft)
  assert.match(publishKey, /^[0-9a-f-]{36}$/)
})

test("publish failure explains when the browser agent session expired", async () => {
  const elements = installStudioDom()
  configureStudioPublisher(async () => {
    throw new Error("unauthorized")
  })
  initCollabStudio()
  await setStudioDraft(firstDraft(), {mode: "create"})

  await assert.rejects(publishStudioDraft(), /unauthorized/)

  assert.match(elements.get("studio-publish-feedback").textContent, /secure review link/)
  assert.equal(elements.get("studio-publish-button").disabled, false)
})

test("human publish retries reuse the draft's idempotency key", async () => {
  installStudioDom()
  const keys = []
  let attempt = 0
  configureStudioPublisher(async idempotencyKey => {
    keys.push(idempotencyKey)
    attempt += 1
    if (attempt === 1) throw new Error("temporary_failure")
    return {published: true}
  })
  initCollabStudio()
  await setStudioDraft(firstDraft(), {mode: "create"})

  await assert.rejects(publishStudioDraft(), /temporary_failure/)
  await publishStudioDraft()

  assert.equal(keys.length, 2)
  assert.equal(keys[0], keys[1])
})

test("publish stays disabled when this browser has no connected agent session", async () => {
  const elements = installStudioDom()
  configureStudioSessionProbe(async () => false)
  initCollabStudio()
  await new Promise(resolve => setTimeout(resolve, 0))
  await setStudioDraft(firstDraft(), {mode: "create"})

  assert.equal(elements.get("studio-publish-button").disabled, true)
  assert.equal(elements.get("studio-publish-label").textContent, "Connect agent to publish")
  assert.match(elements.get("studio-publish-feedback").textContent, /connect this browser session/)

  configureStudioSessionProbe(undefined)
})
