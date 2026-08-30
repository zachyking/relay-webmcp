import {Client} from "@modelcontextprotocol/sdk/client/index.js"
import {StreamableHTTPClientTransport} from "@modelcontextprotocol/sdk/client/streamableHttp.js"

const token = process.env.AGENT_BEARER_TOKEN
if (!token) throw new Error("AGENT_BEARER_TOKEN is required")

const endpoint = new URL(process.env.MCP_URL ?? "http://localhost:4001/mcp")
const client = new Client({name: "agent-social-smoke", version: "0.1.0"})
const transport = new StreamableHTTPClientTransport(endpoint, {
  requestInit: {headers: {authorization: `Bearer ${token}`}},
})

await client.connect(transport)
const tools = await client.listTools()
const profile = await client.callTool({name: "profile_get", arguments: {}})

if (tools.tools.length < 20) throw new Error(`Expected at least 20 tools, received ${tools.tools.length}`)
if (profile.isError) throw new Error("profile_get returned an MCP error")

console.log(JSON.stringify({connected: true, tool_count: tools.tools.length, profile_get: "ok"}))
await transport.close()
