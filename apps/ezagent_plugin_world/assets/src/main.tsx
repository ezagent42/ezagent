import React from "react"
import {createRoot, type Root} from "react-dom/client"

import {AdminSurface} from "./components/Admin"
import {Conversation, type ConversationState} from "./components/Conversation"
import {IdentitiesSurface, type IdentitiesState} from "./components/Identities"
import {LayoutEditor} from "./components/LayoutEditor"
import {PtyTerminalSurface} from "./components/PtyTerminal"
import {SessionsTable} from "./components/SessionsTable"
import {WorldHello} from "./components/WorldHello"
import {WorkspacePluginSurface, type WorkspacePluginState} from "./components/WorkspacePlugin"
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

type WorldState = IdentitiesState & WorkspacePluginState & ConversationState & {
  can_manage_layout?: boolean
  cmdk?: {
    open?: boolean
    query?: string
    results?: Array<Record<string, unknown>>
  }
  component?: string
  current_session_uri?: string | null
  inbound_events?: Array<Record<string, unknown>>
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
            <a className={navClass(state.path, "/workspaces")} href="/workspaces">
              Workspaces
            </a>
            <a className={navClass(state.path, "/plugins")} href="/plugins">
              Plugins
            </a>
            <a className={navClass(state.path, "/profile")} href="/profile">
              Profile
            </a>
          </nav>
        </aside>

        <main className="world-main">
          <header className="world-header">
            <div>
              <p className="world-eyebrow">React/shadcn shell</p>
              <h1>{state.title || pageTitle(state.component)}</h1>
            </div>
            <div className="world-scope">{state.workspace_uri || caller?.workspace_uri || "workspace unavailable"}</div>
            <button
              id="world-cmdk-open"
              className="world-button world-button-default"
              type="button"
              onClick={() => pushEvent?.("world:dispatch", {action: "cmdk.open", args: {}})}
            >
              Command
            </button>
          </header>
          <CommandPalette
            cmdk={state.cmdk}
            onAction={(action, args) => pushEvent?.("world:dispatch", {action, args})}
          />

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
                onCreateSession: (shortName, templateName) => {
                  pushEvent?.("world:dispatch", {
                    action: "session.create",
                    args: {short_name: shortName, template_name: templateName},
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
                onAdminAction: (action, args) => {
                  pushEvent?.("world:dispatch", {action, args})
                },
                onWorkspacePluginAction: (action, args) => {
                  pushEvent?.("world:dispatch", {action, args})
                },
                onChatSend: (sessionUri, text, grants) => {
                  pushEvent?.("world:dispatch", {
                    action: "chat.send",
                    args: {session_uri: sessionUri, text, grants},
                  })
                },
                onSessionSwitch: (sessionUri) => {
                  pushEvent?.("world:dispatch", {
                    action: "session.switch",
                    args: {session_uri: sessionUri},
                  })
                },
                onLoadOlder: (sessionUri, before) => {
                  pushEvent?.("world:dispatch", {
                    action: "chat.load_older",
                    args: {session_uri: sessionUri, before},
                  })
                },
                onMarkDisplayed: (sessionUri, msgId) => {
                  pushEvent?.("world:dispatch", {
                    action: "chat.mark_displayed",
                    args: {session_uri: sessionUri, msg_id: msgId},
                  })
                },
                onInvite: (sessionUri, member) => {
                  pushEvent?.("world:dispatch", {
                    action: "session.invite",
                    args: {session_uri: sessionUri, member},
                  })
                },
                onSessionViewSwitch: (sessionUri, view) => {
                  pushEvent?.("world:dispatch", {
                    action: "session.view.switch",
                    args: {session_uri: sessionUri, view},
                  })
                },
                onOpenSessionPty: (sessionUri, agent) => {
                  pushEvent?.("world:dispatch", {
                    action: "session.pty.open",
                    args: {session_uri: sessionUri, agent},
                  })
                },
                onRestartOrchestrator: (sessionUri) => {
                  pushEvent?.("world:dispatch", {
                    action: "session.orchestrator.restart",
                    args: {session_uri: sessionUri},
                  })
                },
                onAddRoutingRule: (sessionUri, rule) => {
                  pushEvent?.("world:dispatch", {
                    action: "session.routing.add",
                    args: {session_uri: sessionUri, rule},
                  })
                },
                onToggleRoutingRule: (sessionUri, rule) => {
                  pushEvent?.("world:dispatch", {
                    action: "session.routing.toggle",
                    args: {session_uri: sessionUri, ...rule},
                  })
                },
                onPtyInput: (bytes) => {
                  pushEvent?.("pty_input", {bytes})
                },
                onPtyResize: (size) => {
                  pushEvent?.("pty_resize", size)
                },
                onServerEvent,
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

function CommandPalette({
  cmdk,
  onAction,
}: {
  cmdk?: WorldState["cmdk"]
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
  const open = cmdk?.open === true
  const query = String(cmdk?.query || "")
  const results = cmdk?.results || []

  if (!open) return null

  return (
    <div id="world-cmdk" className="world-cmdk" role="dialog" aria-modal="true">
      <button className="world-cmdk-backdrop" type="button" aria-label="Close" onClick={() => onAction("cmdk.close", {})} />
      <div className="world-cmdk-panel">
        <input
          autoFocus
          value={query}
          placeholder="Search"
          onChange={(event) => onAction("cmdk.query", {query: event.target.value})}
          onKeyDown={(event) => {
            if (event.key === "Escape") onAction("cmdk.close", {})
          }}
        />
        <div className="world-cmdk-results">
          {results.map((result) => (
            <button
              key={String(result.key)}
              type="button"
              onClick={() => onAction("cmdk.select", {key: String(result.key)})}
            >
              <span>{String(result.group || "Command")}</span>
              <strong>{String(result.label || result.target || result.key)}</strong>
            </button>
          ))}
          {results.length === 0 && <div className="world-cmdk-empty">No results</div>}
        </div>
      </div>
    </div>
  )
}

type RenderContext = {
  layout: WorldLayout
  state: WorldState
  onJoin: (sessionUri: string) => void
  onCreateSession: (shortName: string, templateName: string) => void
  onManageLayout: (layout: WorldLayout) => void
  onCreateAgent: (agent: Record<string, unknown>) => void
  onAdminAction: (action: string, args: Record<string, unknown>) => void
  onWorkspacePluginAction: (action: string, args: Record<string, unknown>) => void
  onChatSend: (sessionUri: string, text: string, grants: string[]) => void
  onSessionSwitch: (sessionUri: string) => void
  onSessionViewSwitch: (sessionUri: string, view: string) => void
  onOpenSessionPty: (sessionUri: string, agent: string) => void
  onRestartOrchestrator: (sessionUri: string) => void
  onAddRoutingRule: (sessionUri: string, rule: Record<string, string>) => void
  onToggleRoutingRule: (sessionUri: string, rule: {id: string; table: string; enabled: string}) => void
  onLoadOlder: (sessionUri: string, before: string) => void
  onMarkDisplayed: (sessionUri: string, msgId: string) => void
  onInvite: (sessionUri: string, member: string) => void
  onPtyInput: (bytes: string) => void
  onPtyResize: (size: {cols: number; rows: number}) => void
  onServerEvent?: (event: string, callback: (payload: unknown) => void) => void
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
    return <SessionsTable key={component.id} state={context.state} onJoin={context.onJoin} onCreate={context.onCreateSession} />
  }

  if (component.type === "conversation") {
    // Key by session so a switch (push_patch → new state) remounts the
    // island fresh from the server-pushed message stream.
    return (
      <Conversation
        key={`conversation-${context.state.session_uri || "none"}`}
        state={context.state}
        onAddRoutingRule={context.onAddRoutingRule}
        onOpenPty={context.onOpenSessionPty}
        onRestartOrchestrator={context.onRestartOrchestrator}
        onSend={context.onChatSend}
        onSwitch={context.onSessionSwitch}
        onSwitchView={context.onSessionViewSwitch}
        onToggleRoutingRule={context.onToggleRoutingRule}
        onLoadOlder={context.onLoadOlder}
        onMarkDisplayed={context.onMarkDisplayed}
        onInvite={context.onInvite}
        onPtyInput={context.onPtyInput}
        onPtyResize={context.onPtyResize}
        onServerEvent={context.onServerEvent}
      />
    )
  }

  if (component.type === "pty_terminal") {
    return (
      <PtyTerminalSurface
        key={component.id}
        state={context.state}
        onInput={context.onPtyInput}
        onResize={context.onPtyResize}
        onServerEvent={context.onServerEvent}
      />
    )
  }

  if (isAdminComponent(component.type)) {
    return <AdminSurface key={component.id} state={{...context.state, component: component.type}} onAction={context.onAdminAction} />
  }

  if (isWorkspacePluginComponent(component.type)) {
    return (
      <WorkspacePluginSurface
        key={component.id}
        state={{...context.state, component: component.type}}
        onAction={context.onWorkspacePluginAction}
      />
    )
  }

  return <IdentitiesSurface key={component.id} state={{...context.state, component: component.type}} onCreateAgent={context.onCreateAgent} />
}

function navClass(path: string | undefined, href: string) {
  const active =
    href === "/"
      ? path === "/" || path === undefined
      : path === href ||
        (href === "/identities" && path?.startsWith("/identities")) ||
        (href === "/workspaces" && path?.startsWith("/workspaces")) ||
        (href === "/plugins" && path?.startsWith("/plugins"))

  return active ? "world-nav-item world-nav-item-active" : "world-nav-item"
}

function pageTitle(component: string | undefined) {
  switch (component) {
    case "conversation":
      return "Conversation"
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
    case "pty_terminal":
      return "Terminal"
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
    case "workspaces_list":
      return "Workspaces"
    case "workspace_detail":
      return "Workspace detail"
    case "plugins":
      return "Plugins"
    case "profile":
      return "Profile"
    case "auto_derive":
      return "Auto derive"
    case "feishu_bindings":
      return "Feishu bindings"
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

function isWorkspacePluginComponent(type: string) {
  return ["auto_derive", "feishu_bindings", "plugins", "profile", "workspace_detail", "workspaces_list"].includes(type)
}
