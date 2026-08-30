import {createHmac, timingSafeEqual} from "node:crypto"
import {createRemoteJWKSet, jwtVerify, type JWTPayload} from "jose"
import type {AuthInfo} from "@modelcontextprotocol/sdk/server/auth/types.js"
import type {OAuthTokenVerifier} from "@modelcontextprotocol/sdk/server/auth/provider.js"

type OidcMetadata = {issuer: string; jwks_uri: string}

let metadataPromise: Promise<OidcMetadata> | undefined
let remoteJwks: ReturnType<typeof createRemoteJWKSet> | undefined

const required = (name: string): string => {
  const value = process.env[name]
  if (!value) throw new Error(`${name} is required`)
  return value
}

const metadata = async (): Promise<OidcMetadata> => {
  if (!metadataPromise) {
    if (!process.env.OIDC_ISSUER) {
      throw new Error("OIDC is not configured; use an ags_ scoped agent bearer credential")
    }
    const issuer = required("OIDC_ISSUER").replace(/\/$/, "")
    metadataPromise = fetch(`${issuer}/.well-known/openid-configuration`)
      .then(async response => {
        if (!response.ok) throw new Error(`OIDC discovery failed: ${response.status}`)
        return response.json() as Promise<OidcMetadata>
      })
  }
  return metadataPromise
}

const scopesFrom = (payload: JWTPayload): string[] => {
  const claim = payload.scope ?? payload.scopes
  if (typeof claim === "string") return claim.split(" ").filter(Boolean)
  if (Array.isArray(claim)) return claim.filter((scope): scope is string => typeof scope === "string")
  return []
}

export class ZitadelTokenVerifier implements OAuthTokenVerifier {
  async verifyAccessToken(token: string): Promise<AuthInfo> {
    const oidc = await metadata()
    remoteJwks ??= createRemoteJWKSet(new URL(oidc.jwks_uri))

    const audience = required("OIDC_AUDIENCE")
    const {payload} = await jwtVerify(token, remoteJwks, {issuer: oidc.issuer, audience})
    if (!payload.sub) throw new Error("Access token is missing sub")

    const clientId =
      (typeof payload.client_id === "string" && payload.client_id) ||
      (typeof payload.azp === "string" && payload.azp) ||
      "unknown-oauth-client"

    return {
      token,
      clientId,
      scopes: scopesFrom(payload),
      expiresAt: payload.exp,
      resource: new URL(process.env.MCP_PUBLIC_URL ?? "http://localhost:4001/mcp"),
      extra: {subject: payload.sub},
    }
  }
}

type AgentBearerClaims = {
  sub: string
  scopes: string[]
  iat: number
  exp: number
  jti: string
}

const verifyAgentBearer = (token: string): AgentBearerClaims => {
  const match = /^ags_([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/.exec(token)
  if (!match) throw new Error("Invalid agent bearer format")

  const [, payload, encodedSignature] = match
  const expected = createHmac("sha256", required("AGENT_BEARER_SECRET")).update(payload).digest()
  const actual = Buffer.from(encodedSignature, "base64url")

  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    throw new Error("Invalid agent bearer signature")
  }

  const claims = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as AgentBearerClaims
  const now = Math.floor(Date.now() / 1000)
  if (typeof claims.sub !== "string" || !Array.isArray(claims.scopes)) throw new Error("Invalid agent bearer claims")
  if (!Number.isInteger(claims.exp) || claims.exp <= now) throw new Error("Agent bearer expired")
  if (!claims.scopes.every(scope => typeof scope === "string")) throw new Error("Invalid agent bearer scopes")
  return claims
}

export class CompositeTokenVerifier implements OAuthTokenVerifier {
  readonly #oidc = new ZitadelTokenVerifier()

  async verifyAccessToken(token: string): Promise<AuthInfo> {
    if (!token.startsWith("ags_")) return this.#oidc.verifyAccessToken(token)

    const claims = verifyAgentBearer(token)

    return {
      token,
      clientId: "scoped-agent-bearer",
      scopes: claims.scopes,
      expiresAt: claims.exp,
      resource: new URL(process.env.MCP_PUBLIC_URL ?? "http://localhost:4001/mcp"),
      extra: {humanId: claims.sub},
    }
  }
}
