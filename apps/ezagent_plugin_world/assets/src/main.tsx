import React from "react"
import {createRoot, type Root} from "react-dom/client"
import {ArrowLeft, Boxes, ChevronDown, ChevronRight, LogOut, Moon, Sun, User} from "lucide-react"

import {Button} from "./components/ui/primitives"
import {AdminSurface} from "./components/Admin"
import {Conversation, type ConversationState} from "./components/Conversation"
import {IdentitiesSurface, type IdentitiesState} from "./components/Identities"
import {LayoutEditor} from "./components/LayoutEditor"
import {PtyTerminalSurface} from "./components/PtyTerminal"
import {SessionsTable} from "./components/SessionsTable"
import {WorldHello} from "./components/WorldHello"
import {WorkspacePluginSurface, type WorkspacePluginState} from "./components/WorkspacePlugin"
import slotManifest from "./slots.manifest.json"
import "./styles.css"

// Typed-slot manifest — a generated, checked-in projection of
// `Ezagent.World.SlotRegistry` (the SoT). Regenerate with
// `mix world.slots.manifest`. The renderer dispatches purely on the slot's
// `renderer_family`; there is NO unknown-type fallback.
type SlotManifest = {
  version: number
  categories: string[]
  renderer_families: Record<string, string[]>
  slots: Record<string, {renderer_family: string; category: string; title: string; data_source: string}>
  shell_chrome: string[]
}

const SLOTS = (slotManifest as SlotManifest).slots

function rendererFamily(type: string): string {
  const spec = SLOTS[type]
  if (!spec) {
    throw new Error(
      `world: unregistered layout slot type ${JSON.stringify(type)} — ` +
        "register it in Ezagent.World.SlotRegistry and run `mix world.slots.manifest`",
    )
  }
  return spec.renderer_family
}

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
    display_name?: string | null
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
      <div className="flex min-h-screen bg-background text-foreground">
        <aside className="flex w-60 shrink-0 flex-col gap-4 border-r border-border bg-card p-4" aria-label="World navigation">
          <div className="flex h-8 w-8 items-center justify-center rounded-md bg-primary font-semibold text-primary-foreground">W</div>
          <nav className="flex flex-col gap-0.5">
            {NAV_ITEMS.map(([label, href]) => (
              <a className={navClass(state.path, href)} href={href} key={href}>
                {label}
              </a>
            ))}
          </nav>
        </aside>

        <main className="min-w-0 flex-1 p-6">
          <header className="mb-5 flex items-center justify-between gap-4">
            <div className="min-w-0">
              <Breadcrumbs path={state.path} title={state.title || pageTitle(state.component)} />
              <h1 className="mt-1 text-xl font-semibold text-foreground">{state.title || pageTitle(state.component)}</h1>
            </div>
            <div className="flex items-center gap-3">
              <a
                href="/workspaces"
                className="inline-flex items-center gap-1.5 rounded-md border border-border px-2.5 py-1.5 font-mono text-xs text-muted-foreground transition hover:bg-muted hover:text-foreground"
                title="Switch workspace"
              >
                <Boxes aria-hidden="true" className="h-3.5 w-3.5" />
                <span className="max-w-[200px] truncate">
                  {state.workspace_uri || caller?.workspace_uri || "workspace unavailable"}
                </span>
                <ChevronDown aria-hidden="true" className="h-3.5 w-3.5" />
              </a>
              <ThemeToggle />
              <Button
                id="world-cmdk-open"
                type="button"
                variant="secondary"
                size="sm"
                onClick={() => pushEvent?.("world:dispatch", {action: "cmdk.open", args: {}})}
              >
                Command
              </Button>
              <AccountMenu
                displayName={caller?.display_name}
                entityUri={caller?.entity_uri}
              />
            </div>
          </header>
          <CommandPalette
            cmdk={state.cmdk}
            onAction={(action, args) => pushEvent?.("world:dispatch", {action, args})}
          />

          <div className="grid gap-4" data-component-count={components.length}>
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
    <div id="world-cmdk" className="fixed inset-0 z-50 flex items-start justify-center p-4 pt-[12vh]" role="dialog" aria-modal="true">
      <button className="fixed inset-0 bg-black/50" type="button" aria-label="Close" onClick={() => onAction("cmdk.close", {})} />
      <div className="relative z-10 w-full max-w-lg overflow-hidden rounded-lg border border-border bg-card text-card-foreground shadow-2xl">
        <input
          autoFocus
          className="w-full border-b border-border bg-transparent px-4 py-3 text-sm text-foreground outline-none placeholder:text-muted-foreground"
          value={query}
          placeholder="Search"
          onChange={(event) => onAction("cmdk.query", {query: event.target.value})}
          onKeyDown={(event) => {
            if (event.key === "Escape") onAction("cmdk.close", {})
          }}
        />
        <div className="max-h-80 overflow-y-auto py-1">
          {results.map((result) => (
            <button
              key={String(result.key)}
              type="button"
              className="flex w-full items-center gap-2 px-4 py-2 text-left text-sm hover:bg-muted"
              onClick={() => onAction("cmdk.select", {key: String(result.key)})}
            >
              <span className="text-xs text-muted-foreground">{String(result.group || "Command")}</span>
              <strong className="text-foreground">{String(result.label || result.target || result.key)}</strong>
            </button>
          ))}
          {results.length === 0 && <div className="px-4 py-6 text-center text-sm text-muted-foreground">No results</div>}
        </div>
      </div>
    </div>
  )
}

// Shell navigation items (label, href). PR-7 nav IA: Users/Agents are NOT
// separate top-level entries — they are sub-views of Identities (reachable via
// its All/Users/Agents filter bar), so the prior triple entry-point is collapsed
// to a single Identities link.
const NAV_ITEMS: Array<[string, string]> = [
  ["Overview", "/"],
  ["Sessions", "/sessions"],
  ["Identities", "/identities"],
  ["Admin", "/admin"],
  ["Workspaces", "/workspaces"],
  ["Plugins", "/plugins"],
  ["Profile", "/profile"],
]

// The top-level section a (possibly deep) path belongs to — drives the
// breadcrumb root + back link.
function sectionRoot(path?: string): {label: string; href: string} | null {
  if (!path) return null
  if (path.startsWith("/identities")) return {label: "Identities", href: "/identities"}
  if (path.startsWith("/admin")) return {label: "Admin", href: "/admin"}
  if (path.startsWith("/workspaces")) return {label: "Workspaces", href: "/workspaces"}
  if (path.startsWith("/plugins")) return {label: "Plugins", href: "/plugins"}
  if (path.startsWith("/sessions")) return {label: "Sessions", href: "/sessions"}
  return null
}

// Breadcrumb + back affordance for nested pages. Top-level pages (path === the
// section root) render nothing — the h1 alone is the title.
function Breadcrumbs({path, title}: {path?: string; title: string}) {
  const root = sectionRoot(path)
  if (!root || path === root.href) return null

  return (
    <nav className="flex items-center gap-1.5 text-xs text-muted-foreground" aria-label="Breadcrumb">
      <a href={root.href} className="inline-flex items-center gap-1 transition hover:text-foreground">
        <ArrowLeft aria-hidden="true" className="h-3 w-3" />
        {root.label}
      </a>
      <ChevronRight aria-hidden="true" className="h-3 w-3" />
      <span className="text-foreground">{title}</span>
    </nav>
  )
}

function ThemeToggle() {
  const [dark, setDark] = React.useState(false)

  React.useEffect(() => {
    const stored = localStorage.getItem("world-theme")
    const prefersDark = window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false
    const isDark = stored ? stored === "dark" : prefersDark
    document.documentElement.classList.toggle("dark", isDark)
    setDark(isDark)
  }, [])

  const toggle = () => {
    const next = !dark
    document.documentElement.classList.toggle("dark", next)
    localStorage.setItem("world-theme", next ? "dark" : "light")
    setDark(next)
  }

  return (
    <Button type="button" variant="ghost" size="icon" onClick={toggle} aria-label="Toggle theme">
      {dark ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
    </Button>
  )
}

// Phoenix masked CSRF token, rendered into the root layout `<meta>` (root.html.heex).
// The /logout POST is a regular controller form (NOT a world:dispatch over the LV
// socket) because clearing the HTTP session cookie lives in the request layer, not
// the LiveView channel — so it needs the same CSRF token Phoenix forms carry.
function csrfToken(): string {
  return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""
}

// Header account menu — the world UI's logout / switch-account entry point (F3).
// Mirrors the LiveView shell's avatar menu (ide_shell.ex): a display-name button
// opening a dropdown whose only action is a CSRF-protected POST to /logout. Switch
// account = logout + re-auth (no in-place context swap; SPEC v3 §6.4), so "Sign out"
// is also how an operator changes who they are signed in as.
function AccountMenu({displayName, entityUri}: {displayName?: string | null; entityUri?: string | null}) {
  const [open, setOpen] = React.useState(false)
  const ref = React.useRef<HTMLDivElement>(null)
  const formRef = React.useRef<HTMLFormElement>(null)
  const label = displayName || entityUri || "Account"

  React.useEffect(() => {
    if (!open) return undefined

    const onPointer = (event: MouseEvent) => {
      if (ref.current && !ref.current.contains(event.target as Node)) setOpen(false)
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false)
    }

    document.addEventListener("mousedown", onPointer)
    document.addEventListener("keydown", onKey)
    return () => {
      document.removeEventListener("mousedown", onPointer)
      document.removeEventListener("keydown", onKey)
    }
  }, [open])

  return (
    <div className="relative" ref={ref}>
      <button
        type="button"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
        className="inline-flex items-center gap-1.5 rounded-md border border-border px-2.5 py-1.5 text-xs text-muted-foreground transition hover:bg-muted hover:text-foreground"
        title="Account"
      >
        <User aria-hidden="true" className="h-3.5 w-3.5" />
        <span className="max-w-[160px] truncate">{label}</span>
        <ChevronDown aria-hidden="true" className="h-3.5 w-3.5" />
      </button>
      {open && (
        <div
          role="menu"
          className="absolute right-0 z-50 mt-1.5 w-56 overflow-hidden rounded-lg border border-border bg-card text-card-foreground shadow-xl"
        >
          <div className="border-b border-border px-3 py-2">
            <div className="truncate text-sm font-medium text-foreground">{label}</div>
            {entityUri && (
              <div className="truncate font-mono text-xs text-muted-foreground" title={entityUri}>
                {entityUri}
              </div>
            )}
          </div>
          <form ref={formRef} action="/logout" method="post" className="block">
            <input type="hidden" name="_csrf_token" value={csrfToken()} />
            <button
              type="submit"
              role="menuitem"
              onClick={(event) => {
                // The world surface is a LiveView page whose client JS intercepts
                // (and swallows) the native submit event of any form inside the
                // phx-update="ignore" React island — a plain submit never reaches
                // the server. Drive the POST programmatically: form.submit() bypasses
                // the submit event entirely while the CSRF token still rides in the
                // hidden field, so logout actually navigates to /logout.
                event.preventDefault()
                formRef.current?.submit()
              }}
              className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-rose-600 transition hover:bg-muted dark:text-rose-400"
            >
              <LogOut aria-hidden="true" className="h-4 w-4" />
              Sign out
            </button>
          </form>
        </div>
      )}
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
  // Registry-backed dispatch: the slot's type resolves to a renderer family via
  // the checked-in manifest, and the family selects the React renderer. An
  // unregistered type throws in `rendererFamily` (no IdentitiesSurface
  // fallback); an unhandled family throws below.
  switch (rendererFamily(component.type)) {
    case "layout_editor":
      return (
        <LayoutEditor
          key={component.id}
          layout={context.layout}
          canManage={context.state.can_manage_layout === true}
          onManageLayout={context.onManageLayout}
        />
      )

    case "sessions":
      return <SessionsTable key={component.id} state={context.state} onJoin={context.onJoin} onCreate={context.onCreateSession} />

    case "conversation":
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

    case "pty":
      return (
        <PtyTerminalSurface
          key={component.id}
          state={context.state}
          onInput={context.onPtyInput}
          onResize={context.onPtyResize}
          onServerEvent={context.onServerEvent}
        />
      )

    case "admin":
      return <AdminSurface key={component.id} state={{...context.state, component: component.type}} onAction={context.onAdminAction} />

    case "workspace_plugins":
      return (
        <WorkspacePluginSurface
          key={component.id}
          state={{...context.state, component: component.type}}
          onAction={context.onWorkspacePluginAction}
        />
      )

    case "identities":
      return <IdentitiesSurface key={component.id} state={{...context.state, component: component.type}} onCreateAgent={context.onCreateAgent} />

    default:
      throw new Error(
        `world: no renderer for family ${JSON.stringify(SLOTS[component.type]?.renderer_family)} ` +
          `(slot ${JSON.stringify(component.type)})`,
      )
  }
}

function navClass(path: string | undefined, href: string) {
  const active =
    href === "/"
      ? path === "/" || path === undefined
      : path === href ||
        (href === "/identities" && path?.startsWith("/identities")) ||
        (href === "/workspaces" && path?.startsWith("/workspaces")) ||
        (href === "/plugins" && path?.startsWith("/plugins"))

  return active
    ? "rounded-md bg-accent px-3 py-1.5 text-sm font-medium text-accent-foreground"
    : "rounded-md px-3 py-1.5 text-sm font-medium text-muted-foreground transition hover:bg-muted hover:text-foreground"
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

