const storageKey = "relay.collab-studio.v2"
const relationshipModes = new Set(["friendship", "cofounder", "business_partner", "customer"])
const reviewDecisions = new Set(["keep", "cut", "rewrite"])

let studioPublisher
let studioSessionProbe
let studioPersistence
let publishInFlight = false
let studioSessionState = "unknown"
let studioLoadPromise = Promise.resolve()
let reviewSaveTimer
let reviewSavePromise = Promise.resolve()
let reviewDirty = false
let pollingTimer

const element = id => document.getElementById(id)

const cleanText = (value, maxLength) =>
  typeof value === "string" ? value.trim().slice(0, maxLength) : ""

const cleanList = (values, {allowed, maxItems, maxLength}) => {
  if (!Array.isArray(values)) return []

  return [...new Set(values
    .map(value => cleanText(value, maxLength))
    .filter(value => value && (!allowed || allowed.has(value))))]
    .slice(0, maxItems)
}

const readStoredState = () => {
  try {
    return JSON.parse(globalThis.sessionStorage?.getItem(storageKey) || "{}")
  } catch {
    return {}
  }
}

const writeStoredState = state => {
  try {
    globalThis.sessionStorage?.setItem(storageKey, JSON.stringify(state))
  } catch {
    // The review room still works when browser storage is unavailable.
  }
}

const reviewToken = () => {
  const root = element("collab-studio")
  if (root?.dataset.reviewToken) return root.dataset.reviewToken

  const token = decodeURIComponent((globalThis.location?.hash || "").replace(/^#/u, ""))
  if (!token.startsWith("rvw_")) return ""
  if (root) root.dataset.reviewToken = token
  return token
}

const currentSessionId = () =>
  element("collab-studio")?.dataset.sessionId || readStoredState().session_id || ""

const currentReviewUrl = () => {
  const href = globalThis.location?.href || ""
  if ((globalThis.location?.hash || "").startsWith("#rvw_")) return href
  return readStoredState().review_url || href || "/studio"
}

const currentDraft = () => {
  const encoded = element("collab-studio")?.dataset.draft
  if (!encoded) return readStoredState().draft || null

  try {
    return JSON.parse(encoded)
  } catch {
    return null
  }
}

const currentVersion = () => {
  const value = Number(element("collab-studio")?.dataset.draftVersion)
  return Number.isInteger(value) && value > 0 ? value : Number(readStoredState().draft_version || 0)
}

const draftParagraphs = draft =>
  cleanText(draft?.body, 32_768)
    .split(/\n\s*\n|\n/u)
    .map(paragraph => paragraph.trim())
    .filter(Boolean)

const defaultReview = version => ({
  draft_version: version,
  overall_note: "",
  paragraph_feedback: {},
  ready: false,
})

const currentReview = () => {
  const state = readStoredState()
  return state.review?.draft_version === currentVersion()
    ? state.review
    : defaultReview(currentVersion())
}

const renderTokens = (container, values, prefix = "") => {
  if (!container) return
  const tokens = values.map(value => {
    const token = document.createElement("span")
    token.textContent = `${prefix}${value.replaceAll("_", " ")}`
    return token
  })
  container.replaceChildren(...tokens)
}

const setDraftStatus = (label, state, detail) => {
  const status = element("studio-draft-status")
  const updated = element("studio-draft-updated")
  if (status) {
    status.textContent = label
    status.dataset.state = state
  }
  if (updated && detail) updated.textContent = detail
}

const setReviewStatus = (label, state, detail) => {
  const status = element("studio-review-status")
  const helper = element("studio-review-helper")
  if (status) {
    status.textContent = label
    status.dataset.state = state
  }
  if (helper && detail) helper.textContent = detail
}

const updatePublishControl = ({feedback} = {}) => {
  const button = element("studio-publish-button")
  const label = element("studio-publish-label")
  const helper = element("studio-publish-feedback")
  if (!button || !label || !helper) return

  const draftVisible = Boolean(currentDraft())
  const published = Boolean(readStoredState().published)
  let state = "empty"
  let buttonLabel = "Publish this draft"
  let defaultFeedback = "An agent draft must appear before it can be published."

  if (publishInFlight) {
    state = "publishing"
    buttonLabel = "Publishing…"
    defaultFeedback = "Publishing the exact visible draft…"
  } else if (published) {
    state = "published"
    buttonLabel = "Published"
    defaultFeedback = "Published exactly as shown."
  } else if (studioSessionState === "checking") {
    state = "checking-session"
    buttonLabel = "Checking agent session…"
    defaultFeedback = "Confirming that this browser can publish for your connected agent."
  } else if (studioSessionState === "disconnected") {
    state = "disconnected"
    buttonLabel = "Connect agent to publish"
    defaultFeedback = "Ask your agent to connect this browser session before publishing."
  } else if (draftVisible) {
    state = "ready"
    defaultFeedback = "You remain the final editor. Publish only the exact version you approve."
  }

  button.dataset.state = state
  button.disabled =
    publishInFlight ||
    published ||
    studioSessionState === "checking" ||
    studioSessionState === "disconnected" ||
    !draftVisible
  label.textContent = buttonLabel
  helper.textContent = feedback || defaultFeedback
}

const saveReview = review => {
  const state = readStoredState()
  writeStoredState({...state, review})
}

const reviewPayload = () => {
  const review = currentReview()
  return {
    draft_version: currentVersion(),
    overall_note: cleanText(review.overall_note, 2_000),
    paragraph_feedback: review.paragraph_feedback || {},
  }
}

const flushReviewSave = async () => {
  clearTimeout(reviewSaveTimer)
  reviewSaveTimer = undefined
  if (!reviewDirty || !studioPersistence?.saveReview || !reviewToken()) return currentReview()

  const payload = reviewPayload()
  reviewSavePromise = reviewSavePromise.catch(() => {}).then(async () => {
    try {
      const session = await studioPersistence.saveReview(reviewToken(), payload)
      if (currentVersion() === payload.draft_version) {
        reviewDirty = false
        const state = readStoredState()
        writeStoredState({...state, review: session.review, updated_at: session.updated_at})
        setReviewStatus("Saved privately", "available", "Your review is saved to this secure room and available to the agent.")
      }
      return session.review
    } catch (error) {
      setReviewStatus("Save failed", "empty", "Your notes are still visible. Check the connection, then try again.")
      throw error
    }
  })

  return reviewSavePromise
}

const scheduleReviewSave = (delay = 350) => {
  reviewDirty = true
  clearTimeout(reviewSaveTimer)
  reviewSaveTimer = setTimeout(() => flushReviewSave().catch(() => {}), delay)
}

const updateReviewReadyControl = () => {
  const button = element("studio-feedback-ready")
  if (!button) return
  const review = currentReview()
  const hasFeedback = Boolean(
    cleanText(review.overall_note, 2_000) ||
    Object.values(review.paragraph_feedback || {}).some(item => item?.decision || item?.comment),
  )
  button.disabled = !currentDraft() || !hasFeedback
  button.textContent = review.ready ? "Feedback ready ✓" : "Mark feedback ready"
  button.dataset.state = review.ready ? "ready" : hasFeedback ? "available" : "empty"
}

const syncReviewHighlight = (index, decision) => {
  const paragraph = element(`studio-draft-paragraph-${index}`)
  if (paragraph) paragraph.dataset.reviewDecision = decision || "undecided"
}

export const setParagraphFeedback = (index, input = {}) => {
  if (!currentDraft()) throw new Error("visible_draft_required")
  const paragraphs = draftParagraphs(currentDraft())
  if (!Number.isInteger(index) || index < 0 || index >= paragraphs.length) {
    throw new Error("invalid_paragraph_index")
  }

  const review = currentReview()
  const decision = reviewDecisions.has(input.decision) ? input.decision : ""
  const comment = cleanText(input.comment, 1_000)
  const paragraphFeedback = {...(review.paragraph_feedback || {})}

  if (decision || comment) paragraphFeedback[String(index)] = {decision, comment}
  else delete paragraphFeedback[String(index)]

  saveReview({...review, paragraph_feedback: paragraphFeedback, ready: false})
  syncReviewHighlight(index, decision)
  setReviewStatus("Saving…", "reviewing", "Your notes are being saved to this secure review room.")
  scheduleReviewSave(decision ? 0 : 350)
  updateReviewReadyControl()
  return paragraphFeedback[String(index)] || null
}

export const setOverallFeedback = value => {
  if (!currentDraft()) throw new Error("visible_draft_required")
  const review = currentReview()
  const overallNote = cleanText(value, 2_000)
  saveReview({...review, overall_note: overallNote, ready: false})
  setReviewStatus("Saving…", "reviewing", "Your notes are being saved to this secure review room.")
  scheduleReviewSave()
  updateReviewReadyControl()
  return overallNote
}

const reviewCard = (paragraph, index, feedback = {}) => {
  const card = document.createElement("article")
  card.className = "studio-review-card"
  card.dataset.decision = feedback.decision || "undecided"

  const heading = document.createElement("div")
  heading.className = "studio-review-card-heading"
  const number = document.createElement("span")
  number.textContent = String(index + 1).padStart(2, "0")
  const excerpt = document.createElement("p")
  excerpt.textContent = paragraph
  heading.append(number, excerpt)

  const actions = document.createElement("div")
  actions.className = "studio-review-actions"
  for (const decision of reviewDecisions) {
    const button = document.createElement("button")
    button.type = "button"
    button.textContent = decision
    button.dataset.reviewAction = decision
    button.dataset.selected = String(feedback.decision === decision)
    button.addEventListener("click", () => {
      const nextDecision = button.dataset.selected === "true" ? "" : decision
      const latest = currentReview().paragraph_feedback?.[String(index)] || {}
      const saved = setParagraphFeedback(index, {...latest, decision: nextDecision}) || {}
      card.dataset.decision = saved.decision || "undecided"
      for (const action of actions.children) {
        action.dataset.selected = String(action.dataset.reviewAction === saved.decision)
      }
    })
    actions.append(button)
  }

  const comment = document.createElement("textarea")
  comment.maxLength = 1_000
  comment.rows = 2
  comment.value = feedback.comment || ""
  comment.placeholder = "Optional: say exactly what should change…"
  comment.setAttribute("aria-label", `Comment on paragraph ${index + 1}`)
  comment.addEventListener("input", () => {
    const latest = currentReview().paragraph_feedback?.[String(index)] || {}
    setParagraphFeedback(index, {...latest, comment: comment.value})
  })

  card.append(heading, actions, comment)
  return card
}

const renderReview = draft => {
  const empty = element("studio-review-empty")
  const content = element("studio-review-content")
  const sections = element("studio-review-sections")
  const overall = element("studio-overall-feedback")
  const version = element("studio-review-version")
  if (!empty || !content || !sections || !overall || !version) return

  const review = currentReview()
  const cards = draftParagraphs(draft).map((paragraph, index) =>
    reviewCard(paragraph, index, review.paragraph_feedback?.[String(index)] || {}),
  )
  empty.hidden = true
  content.hidden = false
  sections.replaceChildren(...cards)
  overall.value = review.overall_note || ""
  version.textContent = `Reviewing draft v${currentVersion()}`
  setReviewStatus(review.ready ? "Feedback ready" : "Your turn", review.ready ? "ready" : "available",
    review.ready ? "Tell the agent to read your review and revise." : "Mark passages and add only the context the agent is missing.")
  updateReviewReadyControl()
}

const renderDraft = draft => {
  const root = element("collab-studio")
  if (!root) throw new Error("collaboration_studio_not_open")

  root.dataset.draft = JSON.stringify(draft)
  element("studio-draft-empty").hidden = true
  element("studio-draft-content").hidden = false
  element("studio-draft-summary").textContent = draft.summary

  const body = element("studio-draft-body")
  const paragraphs = draftParagraphs(draft).map((paragraph, index) => {
    const node = document.createElement("p")
    node.id = `studio-draft-paragraph-${index}`
    node.dataset.reviewDecision = currentReview().paragraph_feedback?.[String(index)]?.decision || "undecided"
    node.textContent = paragraph
    return node
  })
  body.replaceChildren(...paragraphs)

  element("studio-agent-note").textContent = draft.agent_note || "Ready for the human's editorial review."
  setDraftStatus(currentVersion() > 1 ? `Draft v${currentVersion()}` : "First draft", "ready", "Agent updated just now")
  renderTokens(element("studio-draft-modes"), draft.relationship_modes)
  renderTokens(element("studio-draft-topics"), draft.topic_ids, "#")
  renderReview(draft)
  updatePublishControl()
}

const renderPublished = published => {
  const status = element("studio-draft-status")
  const result = element("studio-published-result")
  const link = element("studio-published-link")
  if (!status || !result || !link) return

  status.textContent = "Published"
  status.dataset.state = "published"
  link.href = published.url
  link.textContent = "Open public post"
  result.hidden = false
  updatePublishControl()
}

const hydrateSession = (session, {replaceUrl = false} = {}) => {
  if (!session?.id || !session?.draft) throw new Error("invalid_studio_session")

  const root = element("collab-studio")
  if (!root) throw new Error("collaboration_studio_not_open")

  const state = {
    draft: session.draft,
    draft_version: session.draft_version,
    review: session.review || defaultReview(session.draft_version),
    published: session.published || null,
    publish_idempotency_key: readStoredState().publish_idempotency_key || crypto.randomUUID(),
    session_id: session.id,
    review_url: session.review_url || currentReviewUrl(),
    expires_at: session.expires_at,
    updated_at: session.updated_at,
  }

  writeStoredState(state)
  root.dataset.sessionId = session.id
  root.dataset.draftVersion = String(session.draft_version)
  root.dataset.draft = JSON.stringify(session.draft)
  renderDraft(session.draft)

  if (session.published) renderPublished(session.published)
  else element("studio-published-result").hidden = true

  if (replaceUrl && session.review_url && globalThis.history?.replaceState) {
    globalThis.history.replaceState({}, "", session.review_url)
    root.dataset.reviewToken = decodeURIComponent(new URL(session.review_url).hash.replace(/^#/u, ""))
  }

  const secureLink = element("studio-secure-link")
  const reviewLink = element("studio-review-link")
  if (secureLink && reviewLink) {
    reviewLink.textContent = state.review_url
    secureLink.hidden = false
  }

  studioSessionState = reviewToken() ? "connected" : studioSessionState
  updatePublishControl()
  return state
}

export const normalizeDraftInput = input => {
  const draft = {
    summary: cleanText(input?.summary, 240),
    body: cleanText(input?.body, 32_768),
    relationship_modes: cleanList(input?.relationship_modes, {
      allowed: relationshipModes,
      maxItems: 4,
      maxLength: 40,
    }),
    topic_ids: cleanList(input?.topic_ids, {maxItems: 12, maxLength: 80}),
    agent_note: cleanText(input?.agent_note, 500),
  }

  if (!draft.body) throw new Error("draft_body_required")
  if (!draft.summary) throw new Error("draft_summary_required")
  if (draft.relationship_modes.length === 0) throw new Error("relationship_mode_required")
  return draft
}

export const buildPostPayload = (draft, idempotencyKey) => ({
  kind: "post",
  relationship_modes: draft.relationship_modes,
  topic_ids: draft.topic_ids,
  visibility: "public",
  language: "en",
  format: "text/plain",
  encoding: "identity",
  rankable_metadata: {
    summary: draft.summary,
    collaboration_surface: "shared_review_room",
  },
  opaque_payload: draft.body,
  idempotency_key: idempotencyKey,
})

const studioReviewSnapshot = () => {
  const draft = currentDraft()
  if (!draft) {
    return {
      source: "human_review_secure_room",
      draft_visible: false,
      next: "Create the first visible draft with studio_draft_create. Do not ask the human to duplicate the conversation in a form.",
    }
  }

  const review = currentReview()
  const paragraphs = draftParagraphs(draft)
  return {
    source: "human_review_secure_room",
    visibility: "private_capability_link_until_published",
    review_url: currentReviewUrl(),
    draft_visible: true,
    draft_version: currentVersion(),
    feedback_ready: Boolean(review.ready),
    overall_note: cleanText(review.overall_note, 2_000),
    paragraph_feedback: paragraphs.map((text, index) => {
      const item = review.paragraph_feedback?.[String(index)] || {}
      return {
        paragraph_index: index,
        text,
        decision: reviewDecisions.has(item.decision) ? item.decision : "undecided",
        comment: cleanText(item.comment, 1_000),
      }
    }),
    current_draft: draft,
    next: review.ready
      ? "Revise with studio_draft_revise using this draft_version. Honor cut/keep/rewrite decisions and explain material choices in agent_note."
      : "Wait until the human says their review is ready before revising.",
  }
}

const refreshStudioSession = async () => {
  await studioLoadPromise
  if (reviewDirty) await flushReviewSave()

  let session
  if (reviewToken() && studioPersistence?.loadByToken) {
    session = await studioPersistence.loadByToken(reviewToken())
  } else if (currentSessionId() && studioPersistence?.loadForAgent) {
    session = await studioPersistence.loadForAgent(currentSessionId())
  }

  if (session) hydrateSession(session)
  return session
}

export const readStudioReview = async () => {
  await refreshStudioSession()
  return studioReviewSnapshot()
}

export const studioSessionReference = () => ({
  id: currentSessionId(),
  review_token: reviewToken(),
  review_url: currentReviewUrl(),
})

export const markStudioFeedbackReady = async () => {
  if (!currentDraft()) throw new Error("visible_draft_required")
  const review = currentReview()
  const hasFeedback = Boolean(
    cleanText(review.overall_note, 2_000) ||
    Object.values(review.paragraph_feedback || {}).some(item => item?.decision || item?.comment),
  )
  if (!hasFeedback) throw new Error("review_feedback_required")

  saveReview({...review, ready: true})
  reviewDirty = true
  await flushReviewSave()

  if (studioPersistence?.markReady && reviewToken()) {
    const session = await studioPersistence.markReady(reviewToken(), currentVersion())
    hydrateSession(session)
  } else {
    saveReview({...currentReview(), ready: true})
  }

  setReviewStatus("Feedback ready", "ready", "Tell the agent to read your review and revise the visible draft.")
  updateReviewReadyControl()
  return studioReviewSnapshot()
}

export const setStudioDraft = async (input, {mode = "create", basedOnVersion, idempotencyKey} = {}) => {
  await studioLoadPromise
  if (reviewToken() && !currentDraft()) await refreshStudioSession()
  const existing = currentDraft()
  const previousVersion = currentVersion()
  if (mode === "create" && existing) throw new Error("draft_already_exists_use_revise")
  if (mode === "revise" && !existing) throw new Error("visible_draft_required")
  if (mode === "revise" && basedOnVersion !== previousVersion) throw new Error("stale_draft_version")

  const draft = normalizeDraftInput(input)

  if (studioPersistence) {
    let session

    if (mode === "create" && studioPersistence.create) {
      session = await studioPersistence.create(draft, idempotencyKey || crypto.randomUUID())
      hydrateSession(session, {replaceUrl: true})
    } else if (mode === "revise" && studioPersistence.revise) {
      session = await studioPersistence.revise(
        currentSessionId(),
        basedOnVersion,
        draft,
        idempotencyKey || crypto.randomUUID(),
      )
      hydrateSession(session)
    }

    if (session) {
      return {
        draft: session.draft,
        draft_version: session.draft_version,
        review_url: session.review_url || currentReviewUrl(),
        session_id: session.id,
      }
    }
  }

  const version = previousVersion + 1
  const state = readStoredState()
  const review = defaultReview(version)
  writeStoredState({
    ...state,
    draft,
    draft_version: version,
    review,
    published: null,
    publish_idempotency_key: crypto.randomUUID(),
  })
  const root = element("collab-studio")
  root.dataset.draftVersion = String(version)
  root.dataset.draft = JSON.stringify(draft)
  renderDraft(draft)
  element("studio-published-result").hidden = true
  if (element("studio-secure-link")) element("studio-secure-link").hidden = true
  return {draft, draft_version: version, review_url: currentReviewUrl()}
}

export const configureStudioPublisher = publisher => {
  studioPublisher = typeof publisher === "function" ? publisher : undefined
}

export const configureStudioPersistence = persistence => {
  studioPersistence = persistence && typeof persistence === "object" ? persistence : undefined
  if (!studioPersistence) {
    clearTimeout(reviewSaveTimer)
    clearInterval(pollingTimer)
    reviewSaveTimer = undefined
    pollingTimer = undefined
    reviewSavePromise = Promise.resolve()
    studioLoadPromise = Promise.resolve()
    reviewDirty = false
  }
}

export const configureStudioSessionProbe = probe => {
  studioSessionProbe = typeof probe === "function" ? probe : undefined
}

const checkStudioSession = async () => {
  if (reviewToken()) {
    studioSessionState = "connected"
    updatePublishControl()
    return
  }

  if (!studioSessionProbe) {
    studioSessionState = "unknown"
    updatePublishControl()
    return
  }

  studioSessionState = "checking"
  updatePublishControl()

  try {
    studioSessionState = (await studioSessionProbe()) ? "connected" : "disconnected"
  } catch {
    studioSessionState = "unknown"
  }

  updatePublishControl()
}

const publishErrorFeedback = error => {
  const code = error?.message

  if (code === "invalid_token" || code === "unauthorized" || code === "request_failed_401") {
    return "This secure review link is no longer authorized. Nothing was posted."
  }

  if (code === "review_link_expired" || code === "request_failed_410") {
    return "This review link expired. Ask the agent to create a fresh room. Nothing was posted."
  }

  return "Could not publish. Nothing was posted—review the draft and try again."
}

export const publishStudioDraft = async () => {
  if (publishInFlight || !currentDraft()) return null

  if (studioSessionState === "disconnected") {
    updatePublishControl({feedback: "Ask your agent to connect this browser session first. Nothing was posted."})
    return null
  }

  if (!studioPublisher) {
    updatePublishControl({feedback: "Publishing is not connected on this page. Reload and try again."})
    return null
  }

  publishInFlight = true
  updatePublishControl()
  let failureFeedback
  const state = readStoredState()
  const idempotencyKey = state.publish_idempotency_key || crypto.randomUUID()
  if (!state.publish_idempotency_key) writeStoredState({...state, publish_idempotency_key: idempotencyKey})

  try {
    return await studioPublisher(idempotencyKey)
  } catch (error) {
    failureFeedback = publishErrorFeedback(error)
    throw error
  } finally {
    publishInFlight = false
    updatePublishControl({feedback: failureFeedback})
  }
}

export const markStudioPublished = content => {
  if (content?.published && content?.draft) {
    hydrateSession(content)
    return content.published
  }

  const draft = currentDraft()
  if (!draft) throw new Error("visible_draft_required")

  const published = {id: content.id, url: `/posts/${encodeURIComponent(content.id)}`}
  const state = readStoredState()
  writeStoredState({...state, draft, published})
  renderPublished(published)
  return published
}

const clearStudio = () => {
  if (!window.confirm("Clear this private review room? Published Relay posts will remain public.")) return

  try {
    globalThis.sessionStorage?.removeItem(storageKey)
  } catch {
    // Clearing the visible room should still work when storage is unavailable.
  }
  const root = element("collab-studio")
  root.dataset.draft = ""
  root.dataset.draftVersion = "0"
  root.dataset.sessionId = ""
  root.dataset.reviewToken = ""
  element("studio-review-empty").hidden = false
  element("studio-review-content").hidden = true
  element("studio-draft-empty").hidden = false
  element("studio-draft-content").hidden = true
  element("studio-published-result").hidden = true
  setReviewStatus("Waiting for draft", "empty", "The agent starts; you review what appears here.")
  setDraftStatus("Waiting for agent", "empty", "")
  if (globalThis.history?.replaceState) globalThis.history.replaceState({}, "", "/studio")
  updatePublishControl()
}

export const initCollabStudio = () => {
  const root = element("collab-studio")
  if (!root || root.dataset.ready === "true") return
  root.dataset.ready = "true"
  studioSessionState = studioSessionProbe ? "checking" : "unknown"

  if (reviewToken() && studioPersistence?.loadByToken) {
    studioSessionState = "checking"
    setDraftStatus("Opening secure room…", "listening", "")
    setReviewStatus("Opening secure room…", "reviewing", "Restoring the latest saved revision.")
    studioLoadPromise = studioPersistence.loadByToken(reviewToken())
      .then(session => {
        hydrateSession(session)
        studioSessionState = "connected"
        return session
      })
      .catch(error => {
        studioSessionState = "disconnected"
        setDraftStatus("Room unavailable", "ended", "")
        setReviewStatus(
          "Link unavailable",
          "empty",
          error?.message === "review_link_expired"
            ? "This secure review link expired. Ask the agent to create a fresh room."
            : "This secure review link is invalid or unavailable.",
        )
        throw error
      })
    studioLoadPromise.catch(() => {})

    clearInterval(pollingTimer)
    pollingTimer = setInterval(async () => {
      if (reviewDirty || document.visibilityState === "hidden") return
      try {
        const session = await studioPersistence.loadByToken(reviewToken())
        const state = readStoredState()
        if (
          session.draft_version !== currentVersion() ||
          session.status === "published" && !state.published
        ) hydrateSession(session)
      } catch {
        // The next explicit action will surface a useful error without interrupting editing.
      }
    }, 2_500)
  }
  updatePublishControl()
  checkStudioSession()

  element("studio-overall-feedback")?.addEventListener("input", event => setOverallFeedback(event.target.value))
  element("studio-feedback-ready")?.addEventListener("click", async () => {
    try {
      await markStudioFeedbackReady()
    } catch {
      setReviewStatus("Add a note first", "empty", "Choose keep, cut, or rewrite—or leave an overall note.")
    }
  })
  element("studio-publish-button")?.addEventListener("click", () => {
    publishStudioDraft().catch(() => {})
  })
  element("studio-clear")?.addEventListener("click", clearStudio)
}
