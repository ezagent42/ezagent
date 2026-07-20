import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {describe, expect, it} from "vitest"

import {TemplateAgentRoleSlot, WorkspacePluginSurface} from "./WorkspacePlugin"

describe("workspace template builder", () => {
  it("marks the template name as required", () => {
    const html = renderToStaticMarkup(
      <WorkspacePluginSurface
        state={{component: "workspace_template_new", name: "system", socialwares: []}}
      />,
    )

    expect(html).toContain('id="world-session-template-name"')
    expect(html).toContain('data-required-marker="true"')
    expect(html).toContain('required=""')
    expect(html).toContain('aria-required="true"')
  })

  it("renders registered flavors as a required select for a fresh agent", () => {
    const html = renderToStaticMarkup(
      <TemplateAgentRoleSlot
        role={{role_name: "developer", fill: "agent", recipe: "developer", flavor: "cc-headless"}}
        slotKey="plugin-developer"
        dataKey="plugin:developer"
        flavors={["cc", "cc-headless", "codex"]}
        onChange={() => undefined}
      />,
    )

    expect(html).toContain('id="template-role-flavor-plugin-developer"')
    expect(html).toContain("<select")
    expect(html).toContain('<option value="cc-headless" selected="">cc-headless</option>')
    expect(html).toContain('required=""')
    expect(html).toContain('aria-required="true"')
  })
})
