import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {describe, expect, it, vi} from "vitest"

import {Conversation, type ConversationState} from "./Conversation"

vi.mock("./PtyTerminal", () => ({
  PtyTerminalSurface: () => <div data-world-test-pty-surface />,
}))
vi.mock("../generated/plugin-page-renderers", () => ({
  pluginPageRenderers: {},
  pluginUnfurlRenderers: [],
}))

const noop = () => undefined

function renderConversation(state: ConversationState) {
  return renderToStaticMarkup(
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
}

const state: ConversationState = {
  active_view: "conversation",
  caller_uri: "entity://system/user/admin",
  session_uri: "session://system/hello-codex/codex-1",
  sessions: [{uri: "session://system/hello-codex/codex-1", name: "codex-1"}],
  views: [{id: "conversation", label: "Conversation", icon: "message-square", mode: "chat"}],
}

describe("terminal view activation", () => {
  it("renders Terminal when the active PTY is present in server-enumerated views", () => {
    const html = renderConversation({
      ...state,
      active_view: "pty",
      active_pty_agent_uri: "entity://system/agent/codex-provisional",
      views: [
        ...state.views!,
        {id: "pty", label: "Terminal", icon: "terminal", mode: "pty"},
      ],
    })

    expect(html).toContain("data-world-test-pty-surface")
  })
})

describe("external Page preview layout", () => {
  it("lets the preview fill the available width and height", () => {
    const html = renderConversation({
      ...state,
      active_view: "hello_page",
      views: [{id: "hello_page", label: "Page", icon: "panel-top", mode: "external"}],
    })

    expect(html).toContain('data-world-subcomponent="external-view"')
    expect(html).toContain('class="relative flex h-full min-h-0 w-full min-w-0 flex-1 flex-col"')
    expect(html).toContain('class="h-full min-h-0 w-full flex-1 border-0 bg-white"')
  })
})

describe("credential-gated agent admission cards", () => {
  it("renders a pending PTY connection card in the message list from its descriptor label", () => {
    const html = renderConversation({
      ...state,
      agent_admissions: [
        {
          role_name: "llm",
          status: "pending_auth",
          attempt_id: null,
          failure_code: null,
          connection: {kind: "pty", label: "连接 Codex"},
        },
      ],
    })

    expect(html).toContain('data-world-agent-admission="llm"')
    expect(html).toContain("连接 Codex")
    expect(html).toContain("data-world-agent-admission-connect")
  })

  it("renders the API-key descriptor label without exposing a provider secret", () => {
    const html = renderConversation({
      ...state,
      agent_admissions: [
        {
          role_name: "llm",
          status: "pending_auth",
          attempt_id: null,
          failure_code: null,
          connection: {kind: "api_key", label: "配置 API key"},
        },
      ],
    })

    expect(html).toContain("配置 API key")
    expect(html).not.toContain("provider")
    expect(html).not.toContain("source_uri")
  })

  it("reuses the secure agent-key form after an API-key candidate is created", () => {
    const html = renderConversation({
      ...state,
      agent_admissions: [
        {
          role_name: "llm",
          status: "authenticating",
          attempt_id: "attempt-1",
          provisional_agent_uri: "entity://system/agent/curl-llm-1",
          failure_code: null,
          connection: {kind: "api_key", label: "配置 API key", provider: "openai"},
        },
      ],
    })

    expect(html).toContain('id="world-api-key-form"')
    expect(html).toContain('data-world-agent-admission="llm"')
    expect(html).toContain('value="openai"')
    expect(html).toContain('readOnly=""')
    expect(html).not.toContain("完成 配置 API key")
  })

  it("renders recovery controls for the existing PTY candidate", () => {
    const html = renderConversation({
      ...state,
      agent_admissions: [
        {
          role_name: "llm",
          status: "authenticating",
          attempt_id: "attempt-pty-1",
          provisional_agent_uri: "entity://system/agent/codex-provisional",
          failure_code: null,
          connection: {kind: "pty", label: "连接 Codex"},
        },
      ],
    })

    expect(html).toContain("data-world-agent-admission-continue")
    expect(html).toContain("继续登录")
    expect(html).toContain("data-world-agent-admission-check")
    expect(html).toContain("检查连接状态")
  })

  it("renders a retry affordance for a failed attempt and no card after admission", () => {
    const retry = renderConversation({
      ...state,
      agent_admissions: [
        {
          role_name: "llm",
          status: "failed",
          attempt_id: "attempt-1",
          failure_code: "authentication_failed",
          connection: {kind: "pty", label: "连接 Codex"},
        },
      ],
    })

    const admitted = renderConversation({
      ...state,
      agent_admissions: [
        {
          role_name: "llm",
          status: "joined",
          attempt_id: "attempt-1",
          failure_code: null,
          connection: {kind: "pty", label: "连接 Codex"},
        },
      ],
    })

    expect(retry).toContain("data-world-agent-admission-retry")
    expect(admitted).not.toContain("data-world-agent-admission")
  })
})
