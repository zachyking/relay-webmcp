import {createHmac} from "node:crypto"
import type {AuthInfo} from "@modelcontextprotocol/sdk/server/auth/types.js"

const coreUrl = (process.env.CORE_URL ?? "http://localhost:4000").replace(/\/$/, "")

const requiredSecret = (): string => {
  const secret = process.env.MCP_INTERNAL_SECRET
  if (!secret) throw new Error("MCP_INTERNAL_SECRET is required")
  return secret
}

export const signedHeaders = (
  auth: AuthInfo,
  method: string,
  pathname: string,
  timestamp = Math.floor(Date.now() / 1000).toString(),
  nonce: string = crypto.randomUUID(),
  idempotencyKey: string = "",
): Record<string, string> => {
  const humanId = auth.extra?.humanId
  const subject = auth.extra?.subject
  const [identityType, identity] =
    typeof humanId === "string" && humanId.length > 0
      ? ["human_id", humanId]
      : typeof subject === "string" && subject.length > 0
        ? ["oidc_sub", subject]
        : [undefined, undefined]

  if (!identityType || !identity) throw new Error("Validated identity is missing")

  const scopes = [...auth.scopes].sort().join(" ")
  const input = [timestamp, nonce, identityType, identity, scopes, auth.clientId, idempotencyKey, method, pathname].join(":")
  const signature = createHmac("sha256", requiredSecret()).update(input).digest("base64url")

  return {
    [identityType === "human_id" ? "x-agent-human-id" : "x-agent-oidc-sub"]: identity,
    "x-agent-scopes": scopes,
    "x-agent-client-id": auth.clientId,
    "x-agent-timestamp": timestamp,
    "x-agent-nonce": nonce,
    "x-agent-signature": signature,
  }
}

export const coreRequest = async (
  auth: AuthInfo,
  method: string,
  path: string,
  body?: unknown,
): Promise<unknown> => {
  const url = new URL(path, coreUrl)
  const bodyRecord = body && typeof body === "object" && !Array.isArray(body) ? body as Record<string, unknown> : undefined
  const suppliedKey = bodyRecord?.idempotency_key
  const idempotencyKey = body === undefined ? "" : typeof suppliedKey === "string" ? suppliedKey : crypto.randomUUID()
  const requestBody = bodyRecord ? Object.fromEntries(Object.entries(bodyRecord).filter(([key]) => key !== "idempotency_key")) : body
  const headers: Record<string, string> = {
    accept: "application/json",
    "x-forwarded-proto": "https",
    ...signedHeaders(auth, method, url.pathname, undefined, undefined, idempotencyKey),
  }

  const options: RequestInit = {
    method,
    headers,
    signal: AbortSignal.timeout(15_000),
  }

  if (body !== undefined) {
    headers["content-type"] = "application/json"
    headers["idempotency-key"] = idempotencyKey
    options.body = JSON.stringify(requestBody)
  }

  const response = await fetch(url, options)
  const payload = await response.json().catch(() => ({error: {code: "invalid_core_response"}}))
  if (!response.ok) throw new Error(`Core ${response.status}: ${JSON.stringify(payload)}`)
  return payload
}

export const compactResult = (payload: unknown): string => {
  const encoded = JSON.stringify(payload)
  if (Buffer.byteLength(encoded) <= 1_500) return encoded

  if (payload && typeof payload === "object" && "data" in payload && Array.isArray(payload.data)) {
    return JSON.stringify({...payload, data: payload.data.slice(0, 3), result_truncated: true})
  }

  return JSON.stringify({result_truncated: true, fetch_by_id_required: true})
}

export const publicDocument = async (path: string): Promise<string> => {
  const response = await fetch(new URL(path, coreUrl), {
    headers: {accept: "text/markdown, text/plain"},
    signal: AbortSignal.timeout(5_000),
  })

  if (!response.ok) throw new Error(`Core public document ${response.status}`)
  return response.text()
}

export const publicJson = async (path: string): Promise<unknown> => {
  const response = await fetch(new URL(path, coreUrl), {
    headers: {accept: "application/json"},
    signal: AbortSignal.timeout(5_000),
  })

  if (!response.ok) throw new Error(`Core public JSON ${response.status}`)
  return response.json()
}
