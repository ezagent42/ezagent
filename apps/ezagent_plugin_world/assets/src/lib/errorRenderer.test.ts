import {describe, expect, it} from "vitest"
import {renderError, categoryTone, errorCardForStatus} from "./errorRenderer"

describe("renderError", () => {
  it("renders Layer 1 when user can fix", () => {
    const rendered = renderError("agent_credential_missing", {is_system_member: true})
    expect(rendered.layer).toBe(1)
    expect(rendered.primaryAction).toEqual({label: "前往修复", href: "/identities/agents"})
  })

  it("renders Layer 2 when user cannot fix but owner exists", () => {
    const rendered = renderError("agent_credential_missing", {is_system_member: false})
    expect(rendered.layer).toBe(2)
    expect(rendered.secondaryAction?.label).toBe("提醒可修复人")
    expect(rendered.secondaryAction?.action).toBe("error.notify_admin")
  })

  it("renders Layer 3 when no fix owner", () => {
    const rendered = renderError("agent_not_ready", {})
    expect(rendered.layer).toBe(3)
    expect(rendered.primaryAction).toBeUndefined()
    expect(rendered.secondaryAction).toBeUndefined()
  })

  it("handles unknown errors as Layer 3", () => {
    const rendered = renderError("unknown", {is_system_member: true})
    expect(rendered.layer).toBe(3)
    expect(rendered.what).toBe("Agent 执行时遇到错误")
  })
})

describe("errorCardForStatus", () => {
  it("returns null for null/undefined/ok/idle so successful dispatches clear the card", () => {
    expect(errorCardForStatus(null, {})).toBeNull()
    expect(errorCardForStatus(undefined, {})).toBeNull()
    expect(errorCardForStatus("ok", {})).toBeNull()
    expect(errorCardForStatus("idle", {})).toBeNull()
  })

  it("renders Layer 1 for a mapped error when the user can fix", () => {
    const card = errorCardForStatus("error:no_api_key", {is_system_member: true})
    expect(card?.code).toBe("agent_credential_missing")
    expect(card?.layer).toBe(1)
  })

  it("renders Layer 2 for a mapped error when the user cannot fix", () => {
    const card = errorCardForStatus("error:no_api_key", {is_system_member: false})
    expect(card?.code).toBe("agent_credential_missing")
    expect(card?.layer).toBe(2)
  })

  it("renders Layer 3 unknown card for unmapped backend reasons", () => {
    const card = errorCardForStatus('error:{:already_exists, "entity://system/agent/x"}', {is_system_member: true})
    expect(card?.code).toBe("unknown")
    expect(card?.layer).toBe(3)
  })
})

describe("categoryTone", () => {
  it("maps credential and permission to danger", () => {
    expect(categoryTone("credential")).toBe("danger")
    expect(categoryTone("permission")).toBe("danger")
  })

  it("maps lifecycle and resource to warning", () => {
    expect(categoryTone("lifecycle")).toBe("warning")
    expect(categoryTone("resource")).toBe("warning")
  })

  it("maps validation and unknown to info", () => {
    expect(categoryTone("validation")).toBe("info")
    expect(categoryTone("unknown")).toBe("info")
  })
})
