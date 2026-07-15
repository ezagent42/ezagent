import {describe, expect, it} from "vitest"

import {
  createOptionsFor,
  displaySessionName,
  filterSessions,
  humanizeSessionName,
  workspaceLabel,
  type RoleSlotChoice,
  type SessionRow,
  type SocialwareRow,
} from "./SessionsTable"

describe("session presentation helpers", () => {
  const sessions: SessionRow[] = [
    {
      uri: "session://demo/chat/support_triage",
      name: "Support Triage",
      workspace_uri: "workspace://demo",
    },
    {
      uri: "session://ops/chat/incident_room",
      workspace_uri: "workspace://ops",
    },
  ]

  it("filters case-insensitively across name, URI, and workspace", () => {
    expect(filterSessions(sessions, "SUPPORT")).toEqual([sessions[0]])
    expect(filterSessions(sessions, "workspace://OPS")).toEqual([sessions[1]])
    expect(filterSessions(sessions, "incident_room")).toEqual([sessions[1]])
  })

  it("derives readable labels without losing canonical workspace identity", () => {
    expect(displaySessionName(sessions[0])).toBe("Support Triage")
    expect(displaySessionName(sessions[1])).toBe("Incident Room")
    expect(humanizeSessionName("conv_release_readiness")).toBe("Release Readiness")
    expect(workspaceLabel("workspace://demo")).toBe("demo")
    expect(workspaceLabel(null)).toBe("")
  })
})

describe("createOptionsFor", () => {
  const socialware: SocialwareRow = {
    name: "deal-room",
    config_id: "config-42",
    content_hash: "sha256:abc",
    roles: [
      {role_name: "analyst", fill: "agent", flavor: "codex"},
      {role_name: "reviewer", fill: "agent", flavor: "cc"},
      {role_name: "owner", fill: "human"},
    ],
  }

  it("builds fresh and reusable agent slots while excluding human roles", () => {
    const choices: Record<string, RoleSlotChoice> = {
      analyst: {role_name: "analyst", mode: "fresh", flavor: "native"},
      reviewer: {
        role_name: "reviewer",
        mode: "reuse",
        agent_uri: "entity://demo/agent/reviewer",
      },
    }

    expect(createOptionsFor(socialware, choices)).toEqual({
      role_slots: [
        {role_name: "analyst", mode: "fresh", flavor: "native", agent_uri: undefined},
        {
          role_name: "reviewer",
          mode: "reuse",
          flavor: undefined,
          agent_uri: "entity://demo/agent/reviewer",
        },
      ],
      socialware_config_id: "config-42",
      socialware_content_hash: "sha256:abc",
    })
  })

  it("drops an incomplete reuse choice instead of dispatching an empty agent URI", () => {
    const choices: Record<string, RoleSlotChoice> = {
      reviewer: {role_name: "reviewer", mode: "reuse"},
    }

    expect(createOptionsFor(socialware, choices).role_slots).toEqual([
      {role_name: "analyst", mode: "fresh", flavor: "codex", agent_uri: undefined},
    ])
  })
})
