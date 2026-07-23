import {describe, expect, it} from "vitest"

import conversationSource from "./Conversation.tsx?raw"
import sessionsTableSource from "./SessionsTable.tsx?raw"

describe("legacy External Mirror navigation", () => {
  it("is absent from the session tools menu", () => {
    expect(conversationSource).not.toContain("data-world-external-mirror-link")
  })

  it("is absent from the sessions detail actions", () => {
    expect(sessionsTableSource).not.toContain("/external_mirror")
  })
})
