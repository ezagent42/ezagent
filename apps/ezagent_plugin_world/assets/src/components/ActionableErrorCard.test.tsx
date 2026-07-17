import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {describe, expect, it} from "vitest"

import {ActionableErrorCard} from "./ActionableErrorCard"

describe("ActionableErrorCard", () => {
  it("renders the recovery contract and a direct repair link", () => {
    const html = renderToStaticMarkup(
      <ActionableErrorCard
        error={{
          code: "agent.credentials_missing",
          severity: "error",
          layer: 1,
          title: "Agent 缺少访问凭据",
          what_happened: "尚未配置 API Key。",
          impact: "本次消息未被处理。",
          next_step: "配置后重新发送。",
          action: {label: "配置 API Key", href: "/identities/agents/example/api-keys"},
          detail: "provider=deepseek",
        }}
      />,
    )

    expect(html).toContain("data-actionable-error")
    expect(html).toContain('data-error-code="agent.credentials_missing"')
    expect(html).toContain("发生了什么")
    expect(html).toContain("影响")
    expect(html).toContain("下一步")
    expect(html).toContain('href="/identities/agents/example/api-keys"')
    expect(html).toContain("provider=deepseek")
  })

  it("keeps administrator-only failures actionable without inventing a direct action", () => {
    const html = renderToStaticMarkup(
      <ActionableErrorCard
        error={{
          code: "agent.provider_quota_exceeded",
          severity: "warning",
          layer: 2,
          title: "模型服务额度不足",
          what_happened: "服务返回额度限制。",
          impact: "暂时无法回复。",
          next_step: "请 workspace 管理员检查服务额度。",
        }}
      />,
    )

    expect(html).toContain("需要管理员")
    expect(html).not.toContain("<a ")
  })
})
