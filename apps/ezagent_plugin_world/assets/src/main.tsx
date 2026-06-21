import React from "react"
import {createRoot, type Root} from "react-dom/client"

import {AdminSurface} from "./components/Admin"
import {IdentitiesSurface, type IdentitiesState} from "./components/Identities"
import {LayoutEditor} from "./components/LayoutEditor"
import {SessionsTable} from "./components/SessionsTable"
import {WorldHello} from "./components/WorldHello"
import "./styles.css"

type WorldLayout = {
  version?: number
  scope?: string
  components?: Array<{
    id: string
    type: string
    placement?: {x?: number; y?: number; w?: number; h?: number}
    props?: Record<string, unknown>
  }>
}

type WorldMountOptions = {
  layout?: WorldLayout
  state?: WorldState
  caller?: {
    entity_uri?: string | null
    workspace_uri?: string | null
  }
  pushEvent?: (event: string, payload: unknown, onReply?: (reply: unknown) => void) => void
  onServerEvent?: (event: string, callback: (payload: unknown) => void) => void
}

type WorldState = IdentitiesState & {
  can_manage_layout?: boolean
  component?: string
  current_session_uri?: string | null
  layout?: WorldLayout
  sessions?: Array<{
    uri: string
    name?: string | null
    workspace_uri?: string | null
  }>
  workspace_uri?: string | null
}

const roots = new WeakMap<HTMLElement, Root>()

export function mountWorld(element: HTMLElement, options: WorldMountOptions = {}) {
  roots.get(element)?.unmount()

  const root = createRoot(element)
  roots.set(element, root)
  root.render(<WorldApp {...options} />)

  return () => {
    root.unmount()
    roots.delete(element)
  }
}

function WorldApp({layout, state: initialState, caller, pushEvent, onServerEvent}: WorldMountOptions) {
  const [currentLayout, setCurrentLayout] = React.useState<WorldLayout>(() => initialState?.layout || layout || {})
  const [state, setState] = React.useState<WorldState>(() => initialState || {})

  React.useEffect(() => {
    if (!onServerEvent) return undefined

    onServerEvent("world:state", (payload) => {
      const next = payload as WorldState

      setState((current) => ({...current, ...next}))
      if (next.layout) setCurrentLayout(next.layout)
    })

    return undefined
  }, [onServerEvent])

  const components = [...(currentLayout.components || [])].sort(
    (a, b) => (a.placement?.y || 0) - (b.placement?.y || 0),
  )

  if (components.length > 0 || state.component === "sessions_table") {
    return (
      <div className="world-screen">
        <aside className="world-sidebar" aria-label="World navigation">
          <div className="world-mark">W</div>
          <nav className="world-nav">
            <a className={navClass(state.path, "/")} href="/">
              Overview
            </a>
            <a className={navClass(state.path, "/sessions")} href="/sessions">
              Sessions
            </a>
            <a className={navClass(state.path, "/identities")} href="/identities">
              Identities
            </a>
            <a className={navClass(state.path, "/identities/users")} href="/identities/users">
              Users
            </a>
            <a className={navClass(state.path, "/identities/agents")} href="/identities/agents">
              Agents
            </a>
            <a className={navClass(state.path, "/admin")} href="/admin">
              Admin
            </a>
          </nav>
        </aside>

        <main className="world-main">
          <header className="world-header">
            <div>
              <p className="world-eyebrow">React/shadcn shell</p>
              <h1>{state.title || pageTitle(state.component)}</h1>
            </div>
            <div className="world-scope">{state.workspace_uri || caller?.workspace_uri || "workspace://system"}</div>
          </header>

          <div className="world-layout-grid" data-component-count={components.length}>
            {(components.length > 0 ? components : [{id: "sessions-table", type: "sessions_table"}]).map((component) =>
              renderLayoutComponent(component, {
                layout: currentLayout,
                state,
                onJoin: (sessionUri) => {
                  pushEvent?.("world:dispatch", {
                    action: "sessions.join",
                    args: {session_uri: sessionUri},
                  })
                },
                onManageLayout: (nextLayout) => {
                  setCurrentLayout(nextLayout)
                  pushEvent?.("world:dispatch", {
                    action: "layout.manage",
                    args: {layout: nextLayout},
                  })
                },
                onCreateAgent: (agent) => {
                  pushEvent?.("world:dispatch", {
                    action: "agents.create",
                    args: {agent},
                  })
                },
              }),
            )}
          </div>
        </main>
      </div>
    )
  }

  const component = layout?.components?.[0]
  const props = (component?.props || {}) as {title?: string}

  return <WorldHello title={props.title} caller={caller} />
}

type RenderContext = {
  layout: WorldLayout
  state: WorldState
  onJoin: (sessionUri: string) => void
  onManageLayout: (layout: WorldLayout) => void
  onCreateAgent: (agent: Record<string, unknown>) => void
}

function renderLayoutComponent(component: NonNullable<WorldLayout["components"]>[number], context: RenderContext) {
  if (component.type === "layout_editor") {
    return (
      <LayoutEditor
        key={component.id}
        layout={context.layout}
        canManage={context.state.can_manage_layout === true}
        onManageLayout={context.onManageLayout}
      />
    )
  }

  if (component.type === "sessions_table") {
    return <SessionsTable key={component.id} state={context.state} onJoin={context.onJoin} />
  }

  if (isAdminComponent(component.type)) {
    return <AdminSurface key={component.id} state={{...context.state, component: component.type}} />
  }

  return <IdentitiesSurface key={component.id} state={{...context.state, component: component.type}} onCreateAgent={context.onCreateAgent} />
}

function navClass(path: string | undefined, href: string) {
  const active =
    href === "/"
      ? path === "/" || path === undefined
      : path === href || (href === "/identities" && path?.startsWith("/identities"))

  return active ? "world-nav-item world-nav-item-active" : "world-nav-item"
}

function pageTitle(component: string | undefined) {
  switch (component) {
    case "identities":
      return "Identities"
    case "users_table":
      return "Users"
    case "agents_table":
      return "Agents"
    case "entity_caps":
      return "Entity caps"
    case "agent_detail":
      return "Agent detail"
    case "agent_new_form":
      return "New agent"
    case "agent_api_keys":
      return "Agent API keys"
    case "agent_extensions":
      return "Agent extensions"
    case "dashboard":
      return "Admin dashboard"
    case "observability":
      return "Observability"
    case "entity_registry":
      return "Entity registry"
    case "snapshots":
      return "Snapshots"
    case "templates":
      return "Templates"
    case "caps_admin":
      return "Capabilities"
    case "authz_audit":
      return "Authz audit"
    case "settings":
      return "Settings"
    case "routing":
      return "Routing"
    case "external_mirror":
      return "External mirror"
    default:
      return "Sessions"
  }
}

function isAdminComponent(type: string) {
  return [
    "authz_audit",
    "caps_admin",
    "dashboard",
    "entity_registry",
    "external_mirror",
    "observability",
    "routing",
    "settings",
    "snapshots",
    "templates",
  ].includes(type)
}
