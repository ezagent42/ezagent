import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {describe, expect, it} from "vitest"

import {agentReadableName, agentReadiness, IdentitiesSurface, type IdentityRow} from "./Identities"

const opaqueAgentOne: IdentityRow = {
  uri: "entity://acme/agent/550e8400-e29b-41d4-a716-446655440000",
  kind: "agent",
  name: "550e8400-e29b-41d4-a716-446655440000",
  display_name: "550e8400-e29b-41d4-a716-446655440000",
  flavor: "cc",
  alive: true,
  credential_status: {status: "authenticated"},
}

const opaqueAgentTwo: IdentityRow = {
  uri: "entity://acme/agent/550e8400-e29b-41d4-a716-446655440001",
  kind: "agent",
  name: "550e8400-e29b-41d4-a716-446655440001",
  flavor: "cc",
  alive: true,
  credential_status: {status: "missing"},
}

const namedOfflineAgent: IdentityRow = {
  uri: "entity://acme/agent/billing-assistant",
  kind: "agent",
  name: "billing-assistant",
  display_name: "Billing Assistant",
  flavor: "curl",
  alive: false,
  credential_status: {status: "authenticated"},
}

const agents = [opaqueAgentOne, opaqueAgentTwo, namedOfflineAgent]

describe("agent directory readability", () => {
  it("replaces opaque UUID names with stable flavor labels while preserving real display names", () => {
    expect(agentReadableName(opaqueAgentOne, 0, agents)).toBe("Claude Code Agent #1")
    expect(agentReadableName(opaqueAgentTwo, 1, agents)).toBe("Claude Code Agent #2")
    expect(agentReadableName(namedOfflineAgent, 2, agents)).toBe("Billing Assistant")
  })

  it("maps list state to ready, missing-key, and offline with credential failures taking priority", () => {
    expect(agentReadiness(opaqueAgentOne)).toBe("ready")
    expect(agentReadiness(opaqueAgentTwo)).toBe("missing-key")
    expect(agentReadiness(namedOfflineAgent)).toBe("offline")
  })

  it("renders readable primary labels and all three status badges", () => {
    const html = renderToStaticMarkup(
      <IdentitiesSurface
        state={{
          component: "agents_table",
          workspace_uri: "workspace://acme",
          agent_flavors: ["cc", "curl"],
          agents,
        }}
      />,
    )

    expect(html).toContain("Claude Code Agent #1")
    expect(html).toContain("Claude Code Agent #2")
    expect(html).toContain("Billing Assistant")
    expect(html).not.toContain(">550e8400-e29b-41d4-a716-446655440000</strong>")
    expect(html).toContain('data-world-agent-status="ready"')
    expect(html).toContain('data-world-agent-status="missing-key"')
    expect(html).toContain('data-world-agent-status="offline"')
  })
})

