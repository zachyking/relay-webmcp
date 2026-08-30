import "./instrumentation.js"
import {createMcpExpressApp} from "@modelcontextprotocol/sdk/server/express.js"
import {requireBearerAuth} from "@modelcontextprotocol/sdk/server/auth/middleware/bearerAuth.js"
import {getOAuthProtectedResourceMetadataUrl} from "@modelcontextprotocol/sdk/server/auth/router.js"
import {StreamableHTTPServerTransport} from "@modelcontextprotocol/sdk/server/streamableHttp.js"
import type {Request, Response} from "express"
import {CompositeTokenVerifier} from "./auth.js"
import {createServer} from "./tools.js"

const port = Number(process.env.PORT ?? 4001)
const publicUrl = new URL(process.env.MCP_PUBLIC_URL ?? `http://localhost:${port}/mcp`)
const coreUrl = new URL(process.env.CORE_URL ?? "http://localhost:4000")
const platformUrl = new URL(process.env.PLATFORM_PUBLIC_URL ?? coreUrl)
const issuer = process.env.OIDC_ISSUER
const scopes = [
  "profile:read", "profile:write", "feed:read", "content:write", "community:write",
  "thread:write", "connection:write", "governance:write", "webhook:write",
]

const app = createMcpExpressApp({host: publicUrl.hostname})
const verifier = new CompositeTokenVerifier()
const metadata = {
  resource: publicUrl.toString(),
  ...(issuer ? {authorization_servers: [issuer]} : {}),
  bearer_methods_supported: ["header"],
  scopes_supported: scopes,
  resource_documentation: new URL("/docs/agents", platformUrl).toString(),
}

app.get("/.well-known/oauth-protected-resource", (_req, res) => res.json(metadata))
app.get("/.well-known/oauth-protected-resource/mcp", (_req, res) => res.json(metadata))
app.get("/healthz", (_req, res) => res.json({status: "ok"}))
app.get("/readyz", async (_req, res) => {
  try {
    const response = await fetch(new URL("/readyz", coreUrl), {
      headers: {"x-forwarded-proto": "https"},
      signal: AbortSignal.timeout(2_000),
    })
    if (!response.ok) return res.status(503).json({status: "unavailable", core: false})
    return res.json({status: "ready", core: true})
  } catch {
    return res.status(503).json({status: "unavailable", core: false})
  }
})

app.post(
  "/mcp",
  requireBearerAuth({verifier, resourceMetadataUrl: getOAuthProtectedResourceMetadataUrl(publicUrl)}),
  async (req: Request, res: Response) => {
    if (!req.auth) return res.status(401).json({error: "unauthorized"})

    const server = createServer(req.auth)
    const transport = new StreamableHTTPServerTransport({sessionIdGenerator: undefined})

    try {
      await server.connect(transport)
      await transport.handleRequest(req, res, req.body)
    } catch (error) {
      console.error("MCP request failed", error)
      if (!res.headersSent) {
        res.status(500).json({jsonrpc: "2.0", error: {code: -32603, message: "Internal server error"}, id: null})
      }
    } finally {
      res.on("close", () => {
        void transport.close()
        void server.close()
      })
    }
  },
)

const methodNotAllowed = (_req: Request, res: Response) => {
  res.status(405).json({jsonrpc: "2.0", error: {code: -32000, message: "Method not allowed"}, id: null})
}
app.get("/mcp", methodNotAllowed)
app.delete("/mcp", methodNotAllowed)

app.listen(port, error => {
  if (error) throw error
  console.log(`Agent Social MCP gateway listening at ${publicUrl}`)
})
