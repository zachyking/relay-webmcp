import assert from "node:assert/strict"
import test from "node:test"
import {Client} from "@modelcontextprotocol/sdk/client/index.js"
import {InMemoryTransport} from "@modelcontextprotocol/sdk/inMemory.js"
import {createServer} from "../src/tools.js"

const auth = {
  token: "test-token",
  clientId: "onboarding-test",
  scopes: ["profile:read"],
  extra: {humanId: "ee3bfe64-e34c-4c21-88e8-4f86f5a1b349"},
}

test("remote MCP initializes with instructions and lists canonical policy resources", async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair()
  const server = createServer(auth)
  const client = new Client({name: "onboarding-test", version: "0.1.0"})

  await server.connect(serverTransport)
  await client.connect(clientTransport)

  try {
    assert.match(client.getInstructions() ?? "", /call onboarding_get/i)
    assert.match(client.getInstructions() ?? "", /platform_rules_get/i)
    assert.match(client.getInstructions() ?? "", /never self-approve/i)

    const tools = await client.listTools()
    assert.ok(tools.tools.some(tool => tool.name === "onboarding_get"))
    assert.ok(tools.tools.some(tool => tool.name === "platform_rules_get"))

    const resources = await client.listResources()
    assert.deepEqual(
      resources.resources.map(resource => resource.uri).sort(),
      [
        "relay://onboarding",
        "relay://policies/community-guidelines",
        "relay://policies/privacy",
        "relay://policies/terms",
      ],
    )
  } finally {
    await client.close()
    await server.close()
  }
})

test("remote MCP onboarding resource reads the canonical Phoenix document", async () => {
  const originalFetch = globalThis.fetch
  globalThis.fetch = async input => {
    assert.equal(String(input), "http://localhost:4000/docs/agents.md")
    return new Response("# Relay agent onboarding guide\n\nCanonical test guide.", {
      status: 200,
      headers: {"content-type": "text/markdown"},
    })
  }

  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair()
  const server = createServer(auth)
  const client = new Client({name: "onboarding-resource-test", version: "0.1.0"})

  try {
    await server.connect(serverTransport)
    await client.connect(clientTransport)

    const result = await client.readResource({uri: "relay://onboarding"})
    assert.match(JSON.stringify(result.contents), /Canonical test guide/)
  } finally {
    await client.close()
    await server.close()
    globalThis.fetch = originalFetch
  }
})
