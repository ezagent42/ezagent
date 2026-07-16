import {describe, expect, it} from "vitest"

import {matchUnfurl} from "./unfurl"

// ㉝ 链接 unfurl 注册机制：kanban 分享接收链接是第一个消费者。
describe("matchUnfurl", () => {
  const relative = "/socialware/kanban/receive?token=SFMyNTY.abc-DEF_123"
  const absolute = `http://192.168.1.20:10042${relative}`

  it("matches a bare relative kanban receive link", () => {
    const m = matchUnfurl(relative)
    expect(m).not.toBeNull()
    expect(m!.renderer.id).toBe("kanban-share")
    expect(m!.url).toBe(relative)
    expect(m!.rest).toBe("")
  })

  it("matches an absolute URL and keeps the full href for navigation", () => {
    const m = matchUnfurl(absolute)
    expect(m).not.toBeNull()
    expect(m!.url).toBe(absolute)
  })

  it("extracts surrounding text as rest (bubble title)", () => {
    const m = matchUnfurl(`【看板分享】看板「demo-board」 ${relative}`)
    expect(m).not.toBeNull()
    expect(m!.rest).toBe("【看板分享】看板「demo-board」")
    expect(m!.url).toBe(relative)
  })

  it("returns null for plain text and unregistered links", () => {
    expect(matchUnfurl("这条消息没有链接")).toBeNull()
    expect(matchUnfurl("https://example.com/some/other?token=abc")).toBeNull()
    // receive 路径但没有 token 参数——不是有效分享链接
    expect(matchUnfurl("/socialware/kanban/receive")).toBeNull()
  })
})
