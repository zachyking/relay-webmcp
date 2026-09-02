const storageKey = "relay.collab-studio.v1"
const relationshipModes = new Set(["friendship", "cofounder", "business_partner", "customer"])

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
    // The collaboration page still works when browser storage is unavailable.
  }
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

const renderTokens = (container, values, prefix = "") => {
  if (!container) return
  const tokens = values.map(value => {
    const token = document.createElement("span")
    token.textContent = `${prefix}${value.replaceAll("_", " ")}`
    return token
  })
  container.replaceChildren(...tokens)
}

const renderDraft = draft => {
  const root = element("collab-studio")
  if (!root) throw new Error("collaboration_studio_not_open")

  root.dataset.draft = JSON.stringify(draft)
  element("studio-draft-empty").hidden = true
  element("studio-draft-content").hidden = false
  element("studio-draft-summary").textContent = draft.summary
  element("studio-draft-body").textContent = draft.body
  element("studio-agent-note").textContent = draft.agent_note || "Shaped from the human's canvas."
  element("studio-draft-status").textContent = "Draft ready"
  element("studio-draft-status").dataset.state = "ready"
  element("studio-draft-updated").textContent = "Agent updated just now"
  renderTokens(element("studio-draft-modes"), draft.relationship_modes)
  renderTokens(element("studio-draft-topics"), draft.topic_ids, "#")
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
}

const persistNotes = notes => {
  const state = readStoredState()
  writeStoredState({...state, notes})
}

const updateNoteCount = notes => {
  const count = element("studio-note-count")
  if (count) count.textContent = `${notes.length.toLocaleString()} / 12,000`
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
    collaboration_surface: "shared_draft",
  },
  opaque_payload: draft.body,
  idempotency_key: idempotencyKey,
})

export const readStudioContext = () => {
  const notes = element("studio-human-notes")
  if (!notes) throw new Error("collaboration_studio_not_open")

  return {
    source: "human_authored_same_page_workspace",
    visibility: "private_to_this_browser_tab_until_published",
    human_notes: notes.value.trim(),
    current_draft: currentDraft(),
    next:
      "Use studio_draft_set to render a concise, truthful public draft on the right. Preserve the human's voice, leave room for connection, and use specific routing metadata.",
  }
}

export const setStudioDraft = input => {
  const draft = normalizeDraftInput(input)
  const state = readStoredState()
  writeStoredState({...state, draft, published: null})
  renderDraft(draft)
  element("studio-published-result").hidden = true
  return draft
}

export const markStudioPublished = content => {
  const draft = currentDraft()
  if (!draft) throw new Error("visible_draft_required")

  const published = {id: content.id, url: `/posts/${encodeURIComponent(content.id)}`}
  const state = readStoredState()
  writeStoredState({...state, draft, published})
  renderPublished(published)
  return published
}

export const initCollabStudio = () => {
  const root = element("collab-studio")
  const notes = element("studio-human-notes")
  if (!root || !notes || root.dataset.ready === "true") return
  root.dataset.ready = "true"

  const stored = readStoredState()
  notes.value = typeof stored.notes === "string" ? stored.notes : ""
  updateNoteCount(notes.value)

  if (stored.draft) renderDraft(stored.draft)
  if (stored.published) renderPublished(stored.published)

  notes.addEventListener("input", () => {
    persistNotes(notes.value)
    updateNoteCount(notes.value)

    if (currentDraft()) {
      const status = element("studio-draft-status")
      status.textContent = "New context"
      status.dataset.state = "changed"
      element("studio-draft-updated").textContent = "Ask the agent to revise"
    }
  })

  element("studio-clear")?.addEventListener("click", () => {
    if (!window.confirm("Clear this private workspace? Published Relay posts will remain public.")) return

    try {
      globalThis.sessionStorage?.removeItem(storageKey)
    } catch {
      // Clearing the visible workspace should still work when storage is unavailable.
    }
    root.dataset.draft = ""
    notes.value = ""
    updateNoteCount("")
    element("studio-draft-empty").hidden = false
    element("studio-draft-content").hidden = true
    element("studio-published-result").hidden = true
    element("studio-draft-status").textContent = "Waiting for agent"
    element("studio-draft-status").dataset.state = "empty"
  })
}
