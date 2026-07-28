import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {describe, expect, it} from "vitest"

import {HelloLlmRoleSlot, installConfigForTemplate, TemplateAgentRoleSlot, WorkspacePluginSurface} from "./WorkspacePlugin"

type ElementProps = {
  children?: React.ReactNode
  id?: string
  onChange?: (event: {target: {value: string}}) => void
}

function elementById(node: React.ReactNode, id: string): React.ReactElement<ElementProps> | undefined {
  if (!React.isValidElement(node)) return undefined

  const element = node as React.ReactElement<ElementProps>
  if (element.props.id === id) return element

  return React.Children.toArray(element.props.children)
    .map((child) => elementById(child, id))
    .find((child) => child !== undefined)
}

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

  it("defaults the Hello LLM selector to curl", () => {
    const html = renderToStaticMarkup(
      <HelloLlmRoleSlot
        role={{role_name: "llm", fill: "agent", recipe: "hello.llm", flavor: "curl"}}
        slotKey="hello-llm"
        flavors={["curl", "cc-headless"]}
        onChange={() => undefined}
      />,
    )

    expect(html).toContain('id="template-hello-flavor-hello-llm"')
    expect(html).toContain('<option value="curl" selected="">curl</option>')
    expect(html).toContain('template-hello-provider-hello-llm')
  })

  it("uses a registered completion flavor instead of unregistered curl", () => {
    const html = renderToStaticMarkup(
      <HelloLlmRoleSlot
        role={{role_name: "llm", fill: "agent", recipe: "hello.llm", flavor: "curl"}}
        slotKey="hello-llm"
        flavors={["cc-headless"]}
        onChange={() => undefined}
      />,
    )

    expect(html).toContain('<option value="cc-headless" selected="">cc-headless</option>')
    expect(html).not.toContain('template-hello-provider-hello-llm')

    const config = installConfigForTemplate(
      {
        name: "hello",
        roles: [{role_name: "llm", fill: "agent", recipe: "hello.llm", flavor: "curl"}],
      },
      {
        "hello:llm": {
          role_name: "llm",
          mode: "fresh",
          flavor: "curl",
          config: {provider: "deepseek", api_url: "https://api.deepseek.com/chat/completions", model: "deepseek-v4-flash"},
        },
      },
      ["cc-headless"],
    )

    expect(config.role_slots[0]).toMatchObject({role_name: "llm", mode: "fresh", flavor: "cc-headless"})
    expect(config.role_slots[0].config).toBeUndefined()
    expect(JSON.stringify(config)).not.toContain("deepseek")
  })

  it("serializes a selected non-curl Hello flavor without curl configuration", () => {
    let choice: {
      role_name: string
      mode: "fresh" | "reuse"
      flavor?: string
      config?: Record<string, unknown>
    } | undefined

    const slot = HelloLlmRoleSlot({
      role: {role_name: "llm", fill: "agent", recipe: "hello.llm", flavor: "curl"},
      slotKey: "hello-llm",
      flavors: ["curl", "cc-headless"],
      onChange: (next) => {
        choice = next
      },
    })
    const flavorSelect = elementById(slot, "template-hello-flavor-hello-llm")

    expect(flavorSelect?.props.onChange).toBeTypeOf("function")
    flavorSelect?.props.onChange?.({target: {value: "cc-headless"}})
    expect(choice).toMatchObject({role_name: "llm", mode: "fresh", flavor: "cc-headless"})
    expect(choice?.config).toBeUndefined()

    const config = installConfigForTemplate(
      {
        name: "hello",
        roles: [{role_name: "llm", fill: "agent", recipe: "hello.llm", flavor: "curl"}],
      },
      {"hello:llm": choice || {role_name: "llm", mode: "fresh"}},
      ["curl", "cc-headless"],
    )

    expect(config.role_slots[0]).toMatchObject({role_name: "llm", mode: "fresh", flavor: "cc-headless"})
    expect(config.role_slots[0].config).toBeUndefined()
    expect(JSON.stringify(config)).not.toContain("deepseek")
  })
})
