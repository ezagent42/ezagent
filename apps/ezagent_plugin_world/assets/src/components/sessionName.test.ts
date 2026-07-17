import {describe, expect, it} from "vitest"

import {normalizeSessionName, sessionNameError} from "./sessionName"

describe("sessionName", () => {
  it("accepts Chinese names and keeps the backend whitespace normalization", () => {
    expect(sessionNameError("客服会话")).toBeNull()
    expect(sessionNameError("客服_01")).toBeNull()
    expect(normalizeSessionName("  客服 会话  ")).toBe("客服-会话")
  })

  it("returns specific, human-readable length errors", () => {
    expect(sessionNameError("客")).toContain("至少需要 2 个字符")
    expect(sessionNameError("客".repeat(31))).toContain("不能超过 30 个字符")
  })

  it("rejects URI structural punctuation before dispatch", () => {
    expect(sessionNameError("客服/会话")).toContain("只能包含")
    expect(sessionNameError("客服:会话")).toContain("只能包含")
  })
})
