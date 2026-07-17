import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {describe, expect, it} from "vitest"

import {WorkspacePluginSurface, type WorkspacePluginState} from "./WorkspacePlugin"

const baseState: WorkspacePluginState = {
  component: "kb",
  title: "Knowledge Base",
  path: "/plugins/kb",
  workspace_uri: "workspace://acme",
  kb_agents: [
    {
      uri: "entity://acme/agent/team-handbook",
      display_name: "团队手册 KB",
    },
  ],
}

function renderKb(state: WorkspacePluginState = baseState) {
  return renderToStaticMarkup(<WorkspacePluginSurface state={state} />)
}

describe("workspace knowledge base import", () => {
  it("starts with the paste flow and exposes file and registered-source alternatives", () => {
    const html = renderKb()

    expect(html).toContain('data-world-component="kb"')
    expect(html).toContain('id="world-kb-paste-form"')
    expect(html).toContain('id="world-kb-paste-title"')
    expect(html).toContain('id="world-kb-paste-content"')
    expect(html).toContain("粘贴文本")
    expect(html).toContain("上传文件")
    expect(html).toContain("已注册来源")
    expect(html).toContain("最多 10 个 .txt / .md 文件")
  })

  it("renders per-document indexed and failed outcomes with actionable messages", () => {
    const html = renderKb({
      ...baseState,
      kb_notice: "imported:1:2",
      kb_error: "some_documents_failed",
      kb_import_results: [
        {title: "Incident Guide", status: "indexed", chunks: 3},
        {title: "Archive", status: "failed", reason: "unsupported_file_type"},
      ],
    })

    expect(html).toContain('id="world-kb-import-results"')
    expect(html).toContain("已完成 1/2 份资料的导入")
    expect(html).toContain("已写入 3 个片段")
    expect(html).toContain("仅支持 .txt 和 .md 文件")
    expect(html).not.toContain("unsupported_file_type")
  })
})
