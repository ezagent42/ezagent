import {describe, expect, it} from "vitest"
import {renderError, categoryTone} from "./errorRenderer"

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
