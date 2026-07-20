import {describe, expect, it, vi} from "vitest"

import {handleBindingsViewSwitch} from "./Conversation"

vi.mock("./PtyTerminal", () => ({PtyTerminalSurface: () => null}))

describe("conversation navigation", () => {
  it("switches Bindings inside the current session view", () => {
    const preventDefault = vi.fn()
    const onSwitchView = vi.fn()
    const sessionUri = "session://system/default/support"

    handleBindingsViewSwitch({preventDefault}, sessionUri, onSwitchView)

    expect(preventDefault).toHaveBeenCalledOnce()
    expect(onSwitchView).toHaveBeenCalledWith(sessionUri, "external_mirror")
  })
})
