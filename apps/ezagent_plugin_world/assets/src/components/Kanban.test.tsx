import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {describe, expect, it} from "vitest"

import {LinkArtifactModal, artifactOpenHref} from "../../../../ezagent_plugin_kanban/assets/src/Kanban"

describe("artifactOpenHref (㊳ 链接产物直开，不拼站点 base)", () => {
  it("绝对 http(s) URL 原样返回", () => {
    expect(artifactOpenHref("https://github.com/x/pull/1")).toBe("https://github.com/x/pull/1")
    expect(artifactOpenHref("http://a.b/c?d=1")).toBe("http://a.b/c?d=1")
  })

  it("任意带 scheme 的 URL 原样返回（不误拼）", () => {
    expect(artifactOpenHref("miro://board/1")).toBe("miro://board/1")
  })

  it("站内绝对路径（uploads 下载 href）原样返回", () => {
    expect(artifactOpenHref("/uploads/download?token=t")).toBe("/uploads/download?token=t")
  })

  it("裸域名补 https://（存量旧数据兜底）", () => {
    expect(artifactOpenHref("example.com/pr/1")).toBe("https://example.com/pr/1")
  })
})

describe("LinkArtifactModal (㊴ 名称+URL 单表单窗)", () => {
  it("新建态：一个窗里同时有名称与 URL 两个输入框", () => {
    const html = renderToStaticMarkup(
      <LinkArtifactModal initial={{name: "", url: ""}} onSave={() => undefined} onClose={() => undefined} />,
    )
    expect(html).toContain("data-world-kanban-link-modal")
    expect(html).toContain("添加链接产物")
    expect(html).toContain("如 github PR #1")
    expect(html).toContain("https://…")
  })

  it("编辑态：回填原名称与原 URL", () => {
    const html = renderToStaticMarkup(
      <LinkArtifactModal
        initial={{ref: "PR #1", name: "PR #1", url: "https://github.com/x/pull/1"}}
        onSave={() => undefined}
        onClose={() => undefined}
      />,
    )
    expect(html).toContain("编辑链接产物")
    expect(html).toContain('value="PR #1"')
    expect(html).toContain('value="https://github.com/x/pull/1"')
  })
})
