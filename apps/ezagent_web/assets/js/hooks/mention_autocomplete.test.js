import {describe, expect, it, vi} from "vitest"

import {MentionAutocomplete} from "./mention_autocomplete"

describe("MentionAutocomplete", () => {
  it("filters object and legacy string members by display name or URI", () => {
    const renderPopover = vi.fn()
    const context = {
      el: {value: "assign @ali", selectionStart: 11},
      members: [
        {uri: "entity://demo/user/alice", display_name: "Alice Chen"},
        "entity://demo/agent/alignment-bot",
        {uri: "entity://demo/user/bob", display_name: "Bob"},
      ],
      renderPopover,
      hidePopover: vi.fn(),
    }

    MentionAutocomplete.handleInput.call(context)

    expect(context._matches).toEqual([
      {uri: "entity://demo/user/alice", display_name: "Alice Chen"},
      {uri: "entity://demo/agent/alignment-bot", display_name: null},
    ])
    expect(renderPopover).toHaveBeenCalledWith(context._matches)
  })

  it("passes the selected URI string when Enter confirms a match", () => {
    const selectMention = vi.fn()
    const event = {key: "Enter", preventDefault: vi.fn()}
    const context = {
      popover: {classList: {contains: () => false}},
      _matches: [{uri: "entity://demo/user/alice", display_name: "Alice"}],
      _activeIndex: 0,
      selectMention,
    }

    MentionAutocomplete.handleKeydown.call(context, event)

    expect(event.preventDefault).toHaveBeenCalledOnce()
    expect(selectMention).toHaveBeenCalledWith("entity://demo/user/alice")
  })

  it("replaces the active mention and emits the normal input event", () => {
    const el = {
      value: "assign @ali",
      selectionStart: 11,
      setSelectionRange: vi.fn(),
      dispatchEvent: vi.fn(),
      focus: vi.fn(),
    }
    const context = {el, hidePopover: vi.fn()}

    MentionAutocomplete.selectMention.call(context, "entity://demo/user/alice")

    expect(el.value).toBe("assign @entity://demo/user/alice ")
    expect(el.setSelectionRange).toHaveBeenCalledWith(33, 33)
    expect(el.dispatchEvent).toHaveBeenCalledWith(
      expect.objectContaining({type: "input"}),
    )
    expect(el.focus).toHaveBeenCalledOnce()
    expect(context.hidePopover).toHaveBeenCalledOnce()
  })

  it("rejects non-string selections instead of inserting object text", () => {
    const context = {
      el: {value: "assign @ali", selectionStart: 11},
      hidePopover: vi.fn(),
    }

    expect(() =>
      MentionAutocomplete.selectMention.call(context, {uri: "entity://demo/user/alice"}),
    ).toThrow(/expected URI string/)
  })
})
