import {describe, expect, it, vi} from "vitest"

import {handleBindingsViewSwitch, toolbarViews} from "./Conversation"

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

  it("omits Routing from the session header view buttons", () => {
    expect(
      toolbarViews([
        {id: "conversation", label: "Conversation", icon: "message-square", mode: "chat"},
        {id: "external_mirror", label: "Bindings", icon: "link", mode: "external"},
        {id: "routing", label: "Routing", icon: "route", mode: "external"},
      ]).map((view) => view.id),
    ).toEqual(["conversation", "external_mirror"])
  })
})
