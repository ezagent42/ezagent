import {describe, expect, it, vi} from "vitest"

import {handleConversationNavigate} from "./Conversation"

vi.mock("./PtyTerminal", () => ({PtyTerminalSurface: () => null}))

describe("conversation navigation", () => {
  it("routes Bindings through World navigation instead of native document navigation", () => {
    const preventDefault = vi.fn()
    const onNavigate = vi.fn()
    const href = "/admin/sessions/session%3A%2F%2Fsystem%2Fdefault%2Fsupport/external_mirror"

    handleConversationNavigate({preventDefault}, href, onNavigate)

    expect(preventDefault).toHaveBeenCalledOnce()
    expect(onNavigate).toHaveBeenCalledWith(href)
  })
})
