import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {describe, expect, it, vi} from "vitest"

import type {ConversationState} from "./Conversation"

vi.mock("./PtyTerminal", () => ({PtyTerminalSurface: () => null}))

const noop = () => undefined

describe("G5 source-2 async agent error cards", () => {
  it("renders a structured message error card without suppressing persisted text", async () => {
    const {Conversation} = await import("./Conversation")
    const state: ConversationState = {
      active_view: "conversation",
      caller_uri: "entity://team/user/alice",
      session_uri: "session://team/default/support",
      sessions: [{uri: "session://team/default/support", name: "Support"}],
      views: [{id: "conversation", label: "对话", icon: "message-square", mode: "chat"}],
      messages: [
        {
          id: "message-async-error",
          sender: "entity://team/agent/curl_support",
          sender_display: "Support Agent",
          sender_kind: "agent",
          text: "[agent error] no_api_key",
          error_card: {
            layer: 2,
            what: "Agent 缺少凭据",
            impact: "当前回复无法生成",
            fix_owner_name: "Allen",
            notify_action: {
              action: "notification.send",
              args: {type: "error_fix_request"},
            },
          },
        },
      ],
    }

    const html = renderToStaticMarkup(
      <Conversation
        state={state}
        onAddRoutingRule={noop}
        onForkConfig={noop}
        onOpenPty={noop}
        onRestartOrchestrator={noop}
        onSend={noop}
        onSwitch={noop}
        onSwitchView={noop}
        onToggleRoutingRule={noop}
        onLoadOlder={noop}
        onMarkDisplayed={noop}
        onInvite={noop}
        onRemoveParticipant={noop}
        onUninstallSocialware={noop}
        onPtyInput={noop}
        onPtyResize={noop}
        onKanbanAction={noop}
        onPublishTemplate={noop}
      />,
    )

    expect(html).toContain("[agent error] no_api_key")
    expect(html).toContain("Agent 缺少凭据")
    expect(html).toContain("当前回复无法生成")
    expect(html).toContain("发送提醒给 Allen")
    expect(html).toContain("data-world-message-error-card")
  })
})
