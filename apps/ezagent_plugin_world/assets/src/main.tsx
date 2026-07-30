import React from "react"
import {createRoot, type Root} from "react-dom/client"
import {ArrowLeft, Boxes, Check, ChevronDown, ChevronRight, Lock, LogOut, Moon, Plus, Sun, User} from "lucide-react"

import {Button} from "./components/ui/primitives"
import {AdminSurface, type AdminState} from "./components/Admin"
import {Conversation, type ConversationState} from "./components/Conversation"
import {IdentitiesSurface, type IdentitiesState} from "./components/Identities"
import {PtyTerminalSurface} from "./components/PtyTerminal"
import {Overview} from "./components/Overview"
import {MarketSurface, type MarketState} from "./components/Market"
import {SessionsTable, type SessionsState} from "./components/SessionsTable"
import {WorldHello} from "./components/WorldHello"
import {WorkspacePluginSurface, type WorkspacePluginState} from "./components/WorkspacePlugin"
import {ErrorMessageCard} from "./components/ErrorMessageCard"
import {errorCardForStatus, type RenderedError} from "./lib/errorRenderer"
import {isPrimaryNavActive, pageTitleForComponent, primaryNavItems, sectionRoot as worldSectionRoot} from "../js/world_ia.js"
import slotManifest from "./slots.manifest.json"
import {pluginPageFullBleedFamilies, pluginPageRenderers} from "./generated/plugin-page-renderers"
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
// G5 错误 toast 自动消失时长(仿 LiveView flash 的轻量通知语义)。
const ERROR_TOAST_AUTO_DISMISS_MS = 5000
// 退出动画时长:到点后先播动画,播完才真正移除 toast 内容。
const ERROR_TOAST_EXIT_MS = 180
const FULL_BLEED_FAMILIES = new Set(["admin", "conversation", "pty", "sessions", "workspace_plugins", ...pluginPageFullBleedFamilies])
const FULL_BLEED_TYPES = new Set(["agents_table"])

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

// Layer-2 modular nav: a top-level sidebar entry contributed by an
// INSTALLED plugin via its `nav_surfaces/0`. View-invariant chrome, passed
// once at mount (see world_renderer.js `data-plugin-nav`).
type PluginNavItem = {
  label: string
  path: string
  icon?: string
}

type WorldMountOptions = {
  layout?: WorldLayout
  state?: WorldState
  pluginNav?: PluginNavItem[]
  caller?: {
    entity_uri?: string | null
    workspace_uri?: string | null
    current_workspace_name?: string | null
    display_name?: string | null
    is_system_member?: boolean
    workspaces?: WorkspaceNavItem[]
  }
  pushEvent?: (event: string, payload: unknown, onReply?: (reply: unknown) => void) => void
  onServerEvent?: (event: string, callback: (payload: unknown) => void) => void
  // WorldRenderer.updated() 通过它把 data-last-dispatch 同步进来
  // （phx-update="ignore" 下 data 属性仍会被 LiveView patch，但 React 不会自动重读）。
  registerDispatchStatusListener?: (listener: ((status: string | null) => void) | null) => void
  // 直接读 island 根元素当前的 data-last-dispatch（比 world:state payload 新）。
  getDispatchStatus?: () => string | null
}

type WorkspaceNavItem = {
  name?: string | null
  uri?: string | null
  current?: boolean
  switch_path?: string | null
  detail_path?: string | null
}

type WorldState = IdentitiesState & WorkspacePluginState & ConversationState & {
  cmdk?: {
    open?: boolean
    query?: string
    results?: Array<Record<string, unknown>>
  }
  component?: string
  current_session_uri?: string | null
  inbound_events?: Array<Record<string, unknown>>
  layout?: WorldLayout
  path?: string
  sessions?: Array<{
    uri: string
    name?: string | null
    workspace_uri?: string | null
  }>
  session_create_pending?: boolean
  socialwares?: Array<{
    name: string
    title?: string | null
    description?: string | null
    config_id?: string | null
    content_hash?: string | null
    scope?: string | null
    workspace_uri?: string | null
    roles?: Array<Record<string, unknown>>
  }>
  title?: string
  workspace_uri?: string | null
  last_dispatch_status?: string | null
}

const roots = new WeakMap<HTMLElement, Root>()

export type WorldHandle = {
  unmount: () => void
  // LiveView hook 侧桥：把最新的 data-last-dispatch 值推给已挂载的 WorldApp。
  setDispatchStatus: (status: string | null) => void
}

export function mountWorld(element: HTMLElement, options: WorldMountOptions = {}): WorldHandle {
  roots.get(element)?.unmount()

  const dispatchStatusListener: {current: ((status: string | null) => void) | null} = {current: null}
  const root = createRoot(element)
  roots.set(element, root)
  root.render(
    <WorldApp
      {...options}
      getDispatchStatus={() => element.dataset.lastDispatch || null}
      registerDispatchStatusListener={(listener) => {
        dispatchStatusListener.current = listener
      }}
    />,
  )

  return {
    unmount: () => {
      root.unmount()
      roots.delete(element)
    },
    setDispatchStatus: (status) => dispatchStatusListener.current?.(status),
  }
}

function WorldApp({layout, state: initialState, pluginNav, caller, pushEvent, onServerEvent, registerDispatchStatusListener, getDispatchStatus}: WorldMountOptions) {
  const [currentLayout, setCurrentLayout] = React.useState<WorldLayout>(() => initialState?.layout || layout || {})
  const [state, setState] = React.useState<WorldState>(() => initialState || {})
  const [errorCard, setErrorCard] = React.useState<RenderedError | null>(() =>
    errorCardForStatus(initialState?.last_dispatch_status, caller || {}),
  )
  // toast 横向滑动:exiting=true 时播退出动画,动画结束才真正移除内容;
  // toastSeq 每次出新卡 +1,作为 key 强制重挂载以重播进入动画。
  const [toastExiting, setToastExiting] = React.useState(false)
  const [toastSeq, setToastSeq] = React.useState(0)
  const errorCardRef = React.useRef<RenderedError | null>(errorCard)
  React.useEffect(() => {
    errorCardRef.current = errorCard
  }, [errorCard])

  // 统一的出卡/收卡入口(稳定 identity,供各事件回调使用):
  // 新卡 → 重置退出态并重播进入动画;null → 有卡时播退出动画而不是直接清空。
  const applyErrorCard = React.useCallback((card: RenderedError | null) => {
    if (card) {
      setToastExiting(false)
      setErrorCard(card)
      setToastSeq((seq) => seq + 1)
    } else if (errorCardRef.current) {
      setToastExiting(true)
    }
  }, [])

  // 岛内发起的 world:dispatch 计数。后端对「相同 error 字符串」不会重复 patch
  // data 属性,所以跟随本次 dispatch 的 world:state 事件到达时,要主动重读
  // dataset 重建卡片(连续两次相同失败也能再次弹出 toast)。
  const pendingDispatch = React.useRef(false)
  const sendEvent = React.useCallback<NonNullable<WorldMountOptions["pushEvent"]>>(
    (event, payload, onReply) => {
      if (event === "world:dispatch") pendingDispatch.current = true
      pushEvent?.(event, payload, onReply)
    },
    [pushEvent],
  )

  const navItems = React.useMemo<typeof NAV_ITEMS>(() => {
    const seen = new Set(NAV_ITEMS.map((item) => item.href))
    const pluginItems = (pluginNav || [])
      .filter((item) => item && typeof item.label === "string" && typeof item.path === "string")
      .filter((item) => !seen.has(item.path))
      .map((item) => ({label: item.label, href: item.path}))
    return [...NAV_ITEMS, ...pluginItems]
  }, [pluginNav])
  React.useEffect(() => {
    if (!registerDispatchStatusListener) return undefined

    registerDispatchStatusListener((status) => {
      applyErrorCard(errorCardForStatus(status, caller || {}))
    })
    return () => registerDispatchStatusListener(null)
  }, [registerDispatchStatusListener, caller, applyErrorCard])

  // toast 自动消失:有新错误时重置计时;到点先播退出动画,动画结束才移除。
  React.useEffect(() => {
    if (!errorCard || toastExiting) return undefined

    const timer = window.setTimeout(() => setToastExiting(true), ERROR_TOAST_AUTO_DISMISS_MS)
    return () => window.clearTimeout(timer)
  }, [errorCard, toastExiting])

  React.useEffect(() => {
    if (!toastExiting) return undefined

    const timer = window.setTimeout(() => {
      setErrorCard(null)
      setToastExiting(false)
    }, ERROR_TOAST_EXIT_MS)
    return () => window.clearTimeout(timer)
  }, [toastExiting])

  React.useEffect(() => {
    if (!onServerEvent) return undefined

    onServerEvent("world:session_created", (payload) => {
      const next = payload as {session_uri?: string}
      if (typeof next.session_uri !== "string" || next.session_uri.length === 0) return

      setState((current) => ({...current, session_create_pending: false, create_error: null}))
    })
    onServerEvent("world:state", (payload) => {
      const next = payload as WorldState
      const clearSessionCreatePending =
        "create_error" in next || "sessions" in next || "current_session_uri" in next

      setState((current) => {
        const merged = {...current, ...next}
        return clearSessionCreatePending ? {...merged, session_create_pending: false} : merged
      })
      if (next.layout) {
        setCurrentLayout(next.layout)
      } else if (next.component === "conversation") {
        // `session.switch` intentionally updates the conversation in place and
        // only pushes the state payload. Keep the island's layout in sync so a
        // session selected from the sessions table renders the conversation
        // surface instead of leaving the old table layout mounted.
        setCurrentLayout({
          version: 1,
          scope: next.workspace_uri || "workspace://system",
          components: [{id: "conversation", type: "conversation", placement: {x: 0, y: 0, w: 12, h: 8}}],
        })
      }

      if (pendingDispatch.current) {
        // 本次 world:state 跟随岛内发起的 dispatch:以 dataset 里的最新
        // last_dispatch_status 为准(payload 不带这个 key)。
        // payload 若带后端已人性化的错误文本(如 agent 创建的 create_error
        // 「同名 agent 已存在:…」),优先用它做详情,与界面横幅保持一致。
        pendingDispatch.current = false
        const card = errorCardForStatus(getDispatchStatus?.() ?? null, caller || {})
        const humanDetail =
          typeof next.create_error === "string" && next.create_error.trim() ? next.create_error : undefined
        applyErrorCard(card && humanDetail ? {...card, detail: humanDetail} : card)
      } else if ("last_dispatch_status" in next) {
        applyErrorCard(errorCardForStatus(next.last_dispatch_status, caller || {}))
      }
    })

    onServerEvent("world:surface_state", (payload) => {
      const next = payload as {surface?: string; state?: WorldState}
      if (!next.state || typeof next.surface !== "string") return

      setState((current) => ({...current, ...next.state}))
      if (next.state.layout) setCurrentLayout(next.state.layout)
    })

    onServerEvent("world:url", (payload) => {
      const next = payload as {path?: string}
      if (next.path && typeof window !== "undefined") window.history.pushState({}, "", next.path)
    })

    return undefined
  }, [onServerEvent, caller, getDispatchStatus, applyErrorCard])

  const components = [...(currentLayout.components || [])].sort(
    (a, b) => (a.placement?.y || 0) - (b.placement?.y || 0),
  )
  const renderedComponents = components.length > 0 ? components : [{id: "sessions-table", type: "sessions_table"}]
  const fullBleed = renderedComponents.some((component) => {
    const family = rendererFamily(component.type)
    return FULL_BLEED_FAMILIES.has(family) || FULL_BLEED_TYPES.has(component.type)
  })
  const topAction = topActionForSection(state.path)
  const shellTitle = state.title || pageTitle(state.component)

  if (components.length > 0 || state.component === "sessions_table") {
    return (
      <div
        className="grid h-dvh min-h-0 grid-rows-[auto_minmax(0,1fr)] overflow-hidden bg-background text-foreground sm:grid-rows-[54px_minmax(0,1fr)]"
        data-world-shell="prototype"
      >
        {errorCard && (
          // 浮动 toast:fixed 定位不占文档流(与 core_components flash 同款
          // right-4 + z-50 + w-80/sm:w-96 惯例),数秒后自动消失;
          // 出现/消失都做横向滑动(key=toastSeq 保证重复错误重播进入动画)。
          <div
            key={toastSeq}
            className={`fixed right-4 top-4 z-50 w-80 max-w-[calc(100vw-2rem)] sm:w-96 ${toastExiting ? "world-toast-exit" : "world-toast-enter"}`}
            data-world-error-toast
          >
            <ErrorMessageCard
              error={errorCard}
              onDismiss={() => applyErrorCard(null)}
              onAction={(action, args) => sendEvent("world:dispatch", {action, args})}
              onNavigate={(href) => sendEvent("world:navigate", {to: href})}
            />
          </div>
        )}
        <header
          className="grid grid-cols-1 items-center gap-3 border-b border-border bg-card px-3 py-2 shadow-sm sm:grid-cols-[250px_minmax(260px,1fr)_auto] sm:px-3.5 sm:py-0"
          data-world-topbar
        >
          <div className="flex min-w-0 items-center gap-2.5">
            <div className="grid h-7 w-7 shrink-0 place-items-center rounded-[7px] border-2 border-primary bg-primary font-mono text-[13px] font-bold text-primary-foreground">
              ez
            </div>
            <WorkspaceSwitcher
              currentWorkspaceName={caller?.current_workspace_name}
              currentWorkspaceUri={state.workspace_uri || caller?.workspace_uri}
              isSystemMember={caller?.is_system_member === true}
              workspaces={caller?.workspaces || []}
            />
          </div>

          <nav
            className="inline-flex min-w-0 justify-self-stretch rounded-[10px] border border-border bg-muted p-[3px] sm:justify-self-center"
            aria-label="Primary"
            data-world-primary-nav
          >
            <div className="grid w-full grid-cols-3 gap-1 sm:flex sm:w-auto">
              {navItems.map((item) => {
                const href = navHref(item.href, state)

                return (
                  <a
                    className={navClass(state.path, item.href)}
                    href={href}
                    key={item.href}
                    onClick={(event) => handleWorldNavClick(event, href, pushEvent)}
                  >
                    {item.label}
                  </a>
                )
              })}
            </div>
          </nav>

          <div className="flex min-w-0 items-center justify-end gap-2">
            {topAction && (
              <a
                data-world-top-action
                className="inline-flex min-h-[34px] items-center justify-center gap-1.5 whitespace-nowrap rounded-[10px] border border-primary bg-primary px-3 text-[13px] font-semibold text-primary-foreground transition hover:opacity-90"
                href={topAction.href}
                onClick={(event) => handleWorldNavClick(event, topAction.href, pushEvent)}
              >
                {topAction.icon === "plus" && <Plus aria-hidden="true" className="h-4 w-4" />}
                {topAction.label}
              </a>
            )}
            <AccountMenu
              displayName={caller?.display_name}
              entityUri={caller?.entity_uri}
              capsPath={entityCapsPath(caller?.entity_uri)}
              themeControl={<ThemeToggle variant="menu" />}
            />
          </div>
        </header>

        <main className={fullBleed ? "h-full min-h-0 min-w-0 overflow-hidden" : "h-full min-h-0 min-w-0 overflow-auto p-4 sm:p-6"} data-world-content>
          {!fullBleed && (
            <header className="mb-5 flex flex-col items-start justify-between gap-3 sm:flex-row sm:items-center sm:gap-4">
              <div className="min-w-0 flex-1 sm:flex-none">
                <Breadcrumbs path={state.path} title={shellTitle} />
                {showShellTitle(state.path) && (
                  <h1 className="mt-1 text-xl font-semibold leading-tight text-foreground">{shellTitle}</h1>
                )}
              </div>
            </header>
          )}
          <CommandPalette
            cmdk={state.cmdk}
            onAction={(action, args) => sendEvent("world:dispatch", {action, args})}
          />

          <div className={fullBleed ? "h-full min-h-0 min-w-0" : "grid min-w-0 gap-4"} data-component-count={components.length}>
            {renderedComponents.map((component) =>
              renderLayoutComponent(component, {
                layout: currentLayout,
                state,
                pushEvent,
                onJoin: (sessionUri) => {
                  // The sessions-TABLE row click is a first-touch "open this
                  // session" affordance — the direct `sessions.join` action
                  // (WorldLive's dispatch_session_join/2), not the
                  // conversation-group `session.switch` (switching sessions
                  // from WITHIN an already-open conversation rail, wired
                  // separately below via onSessionSwitch). The two are not
                  // interchangeable: only sessions.join's push_patch ->
                  // handle_params round trip supplies a `layout` in the
                  // pushed world:state (see the world:state handler above);
                  // session.switch's state never carries one.
                  sendEvent("world:dispatch", {
                    action: "sessions.join",
                    args: {session_uri: sessionUri},
                  })
                },
                onCreateSession: (shortName, templateName, socialwareRef, options) => {
                  const args: Record<string, unknown> = {short_name: shortName, template_name: templateName}
                  if (socialwareRef) args.socialware_ref = socialwareRef
                  if (options?.role_slots) args.role_slots = options.role_slots
                  if (options?.socialware_config_id) args.socialware_config_id = options.socialware_config_id
                  if (options?.socialware_content_hash) args.socialware_content_hash = options.socialware_content_hash
                  setState((current) => ({...current, session_create_pending: true, create_error: null}))
                  sendEvent("world:dispatch", {
                    action: "session.create",
                    args,
                  })
                },
                onPublishTemplate: (sessionUri, name) => {
                  sendEvent("world:dispatch", {
                    action: "session.publish_template",
                    args: {session_uri: sessionUri, name},
                  })
                },
                onCreateAgent: (agent) => {
                  sendEvent("world:dispatch", {
                    action: "agents.create",
                    args: {agent},
                  })
                },
                onCreateUser: (user) => {
                  sendEvent("world:dispatch", {
                    action: "users.create",
                    args: {user},
                  })
                },
                onSaveUserProfile: (payload) => {
                  sendEvent("world:dispatch", {
                    action: "users.profile.save",
                    args: payload,
                  })
                },
                onSetUserPassword: (payload) => {
                  sendEvent("world:dispatch", {
                    action: "users.password.set",
                    args: payload,
                  })
                },
                onDisableUser: (payload) => {
                  sendEvent("world:dispatch", {
                    action: "users.disable",
                    args: payload,
                  })
                },
                onEnableUser: (payload) => {
                  sendEvent("world:dispatch", {
                    action: "users.enable",
                    args: payload,
                  })
                },
                onDeleteAgent: (agentUri: string) => {
                  sendEvent("world:dispatch", {
                    action: "agents.delete",
                    args: {agent_uri: agentUri},
                  })
                },
                onConfigUpdate: (agentUri: string, key: string, patch: Record<string, unknown>) => {
                  sendEvent("world:dispatch", {
                    action: "agents.config.update",
                    args: {agent_uri: agentUri, layer: "user", key, patch},
                  })
                },
                onConfigDeletePath: (agentUri: string, key: string, path: string[]) => {
                  sendEvent("world:dispatch", {
                    action: "agents.config.delete_path",
                    args: {agent_uri: agentUri, layer: "user", key, path},
                  })
                },
                onPutApiKey: (payload) => {
                  sendEvent("world:dispatch", {
                    action: "agent.api_key.put",
                    args: payload,
                  })
                },
                onDeleteApiKey: (payload) => {
                  sendEvent("world:dispatch", {
                    action: "agent.api_key.delete",
                    args: payload,
                  })
                },
                onAdminAction: (action, args) => {
                  sendEvent("world:dispatch", {action, args})
                },
                onWorkspacePluginAction: (action, args) => {
                  sendEvent("world:dispatch", {action, args})
                },
                onChatSend: (sessionUri, text, grants) => {
                  sendEvent("world:dispatch", {
                    action: "chat.send",
                    args: {session_uri: sessionUri, text, grants},
                  })
                },
                onSessionSwitch: (sessionUri) => {
                  sendEvent("world:dispatch", {
                    action: "session.switch",
                    args: {session_uri: sessionUri},
                  })
                },
                onLoadOlder: (sessionUri, before) => {
                  sendEvent("world:dispatch", {
                    action: "chat.load_older",
                    args: {session_uri: sessionUri, before},
                  })
                },
                onMarkDisplayed: (sessionUri, msgId) => {
                  sendEvent("world:dispatch", {
                    action: "chat.mark_displayed",
                    args: {session_uri: sessionUri, msg_id: msgId},
                  })
                },
                onInvite: (sessionUri, member) => {
                  sendEvent("world:dispatch", {
                    action: "session.invite",
                    args: {session_uri: sessionUri, member},
                  })
                },
                onAssignRole: (sessionUri, member, roleName) => {
                  sendEvent("world:dispatch", {
                    action: "session.assign_role",
                    args: {session_uri: sessionUri, member, role_name: roleName},
                  })
                },
                onRemoveParticipant: (sessionUri, participant) => {
                  sendEvent("world:dispatch", {
                    action: "session.remove_participant",
                    args: {session_uri: sessionUri, participant},
                  })
                },
                onUninstallSocialware: (sessionUri, ref) => {
                  sendEvent("world:dispatch", {
                    action: "session.socialware.uninstall",
                    args: {session_uri: sessionUri, ref},
                  })
                },
                onSessionViewSwitch: (sessionUri, view) => {
                  sendEvent("world:dispatch", {
                    action: "session.view.switch",
                    args: {session_uri: sessionUri, view},
                  })
                },
                onOpenSessionPty: (sessionUri, agent) => {
                  sendEvent("world:dispatch", {
                    action: "session.pty.open",
                    args: {session_uri: sessionUri, agent},
                  })
                },
                onForkConfig: (sessionUri) => {
                  sendEvent("world:dispatch", {
                    action: "session.fork_config",
                    args: {session_uri: sessionUri},
                  })
                },
                onRestartOrchestrator: (sessionUri) => {
                  sendEvent("world:dispatch", {
                    action: "session.orchestrator.restart",
                    args: {session_uri: sessionUri},
                  })
                },
                onAddRoutingRule: (sessionUri, rule) => {
                  sendEvent("world:dispatch", {
                    action: "session.routing.add",
                    args: {session_uri: sessionUri, rule},
                  })
                },
                onToggleRoutingRule: (sessionUri, rule) => {
                  sendEvent("world:dispatch", {
                    action: "session.routing.toggle",
                    args: {session_uri: sessionUri, ...rule},
                  })
                },
                onPtyInput: (bytes) => {
                  sendEvent("pty_input", {bytes})
                },
                onPtyResize: (size) => {
                  sendEvent("pty_resize", size)
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

const NAV_ITEMS = primaryNavItems()

// The top-level section a (possibly deep) path belongs to — drives the
// breadcrumb root + back link.
function sectionRoot(path?: string): {label: string; href: string} | null {
  return worldSectionRoot(path)
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

function topActionForSection(path?: string): {label: string; href: string; icon?: "plus"} | null {
  const root = sectionRoot(path)

  if (root?.label === "Agents") {
    return {label: "New agent", href: "/identities/agents/new", icon: "plus"}
  }

  if (root?.label === "Manage") {
    return {label: "View audit", href: "/admin/audit/authz"}
  }

  return null
}

function showShellTitle(path?: string) {
  const root = sectionRoot(path)
  return !root || path === root.href
}

function ThemeToggle({variant = "icon"}: {variant?: "icon" | "menu"}) {
  const [dark, setDark] = React.useState(false)

  React.useEffect(() => {
    const stored = localStorage.getItem("phx:theme")
    const prefersDark = window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false
    const isDark = stored ? stored === "dark" : prefersDark
    document.documentElement.setAttribute("data-theme", isDark ? "dark" : "light")
    setDark(isDark)
  }, [])

  const toggle = () => {
    const next = !dark
    document.documentElement.setAttribute("data-theme", next ? "dark" : "light")
    localStorage.setItem("phx:theme", next ? "dark" : "light")
    setDark(next)
  }

  if (variant === "menu") {
    return (
      <button
        type="button"
        role="menuitem"
        onClick={toggle}
        className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-muted-foreground transition hover:bg-muted hover:text-foreground"
      >
        {dark ? <Sun aria-hidden="true" className="h-4 w-4" /> : <Moon aria-hidden="true" className="h-4 w-4" />}
        {dark ? "Light mode" : "Dark mode"}
      </button>
    )
  }

  return (
    <Button type="button" variant="ghost" size="icon" onClick={toggle} aria-label="Toggle theme">
      {dark ? <Sun aria-hidden="true" className="h-4 w-4" /> : <Moon aria-hidden="true" className="h-4 w-4" />}
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

function WorkspaceSwitcher({
  currentWorkspaceName,
  currentWorkspaceUri,
  isSystemMember,
  workspaces,
}: {
  currentWorkspaceName?: string | null
  currentWorkspaceUri?: string | null
  isSystemMember: boolean
  workspaces: WorkspaceNavItem[]
}) {
  const [open, setOpen] = React.useState(false)
  const ref = React.useRef<HTMLDivElement>(null)
  const label = currentWorkspaceName || currentWorkspaceUri || "workspace"

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
    <div className="relative max-w-full" ref={ref}>
      <button
        type="button"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={`Switch workspace: ezagent / ${label}`}
        title="Switch workspace"
        onClick={() => setOpen((value) => !value)}
        className="inline-flex min-h-[34px] max-w-full items-center justify-between gap-1.5 rounded-[10px] border border-border bg-muted px-2.5 py-1.5 text-xs text-muted-foreground transition hover:bg-muted hover:text-foreground"
      >
        <Boxes aria-hidden="true" className="h-3.5 w-3.5 shrink-0" />
        <span className="min-w-0 truncate">
          <span className="font-semibold text-foreground">ezagent</span>
          <span className="mx-1 text-muted-foreground">/</span>
          <span className="font-mono">{label}</span>
        </span>
        <ChevronDown aria-hidden="true" className="h-3.5 w-3.5 shrink-0" />
      </button>

      {open && (
        <div
          role="menu"
          className="absolute right-0 z-50 mt-1.5 w-72 overflow-hidden rounded-lg border border-border bg-card text-card-foreground shadow-xl sm:left-0 sm:right-auto"
        >
          <div className="border-b border-border px-3 py-2 text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
            Workspaces
          </div>
          <div className="max-h-72 overflow-y-auto py-1">
            {workspaces.map((workspace) => {
              const name = workspaceLabel(workspace)
              const current = workspace.current === true || workspace.uri === currentWorkspaceUri

              if (current) {
                return (
                  <div
                    key={workspace.uri || workspace.name || name}
                    role="menuitem"
                    aria-current="true"
                    className="flex items-center justify-between gap-2 bg-muted/50 px-3 py-2 text-xs"
                  >
                    <WorkspaceMenuLabel workspace={workspace} />
                    <Check aria-hidden="true" className="h-3.5 w-3.5 shrink-0 text-foreground" />
                  </div>
                )
              }

              return (
                <form
                  key={workspace.uri || workspace.name || name}
                  action={workspace.switch_path || "/workspaces/switch"}
                  method="post"
                  className="block"
                >
                  <input type="hidden" name="_csrf_token" value={csrfToken()} />
                  <input type="hidden" name="workspace" value={String(workspace.name || name)} />
                  <button
                    type="submit"
                    role="menuitem"
                    title={isSystemMember ? `Operate on workspace ${name}` : `Sign in to workspace ${name}`}
                    onClick={(event) => {
                      event.preventDefault()
                      event.currentTarget.form?.submit()
                    }}
                    className="flex w-full items-center justify-between gap-2 px-3 py-2 text-left text-xs text-muted-foreground transition hover:bg-muted hover:text-foreground"
                  >
                    <WorkspaceMenuLabel workspace={workspace} />
                    {!isSystemMember && <Lock aria-hidden="true" className="h-3.5 w-3.5 shrink-0" />}
                  </button>
                </form>
              )
            })}
            {workspaces.length === 0 && <div className="px-3 py-3 text-xs text-muted-foreground">No workspaces</div>}
          </div>
          <div className="border-t border-border px-3 py-2">
            <a href="/workspaces" className="text-xs font-medium text-foreground transition hover:text-primary">
              Manage workspaces
            </a>
          </div>
        </div>
      )}
    </div>
  )
}

function WorkspaceMenuLabel({workspace}: {workspace: WorkspaceNavItem}) {
  return (
    <span className="min-w-0">
      <span className="block truncate font-mono text-foreground">{workspaceLabel(workspace)}</span>
      {workspace.uri && (
        <span className="block truncate font-mono text-[11px] text-muted-foreground" title={workspace.uri}>
          {workspace.uri}
        </span>
      )}
    </span>
  )
}

function workspaceLabel(workspace: WorkspaceNavItem): string {
  return String(workspace.name || workspace.uri || "workspace")
}

// Header account menu — personal account state lives here rather than in the
// primary nav. Switch account = logout + re-auth (no in-place context swap;
// SPEC v3 §6.4), so "Sign out" is also how an operator changes identity.
function AccountMenu({
  displayName,
  entityUri,
  capsPath,
  themeControl,
}: {
  displayName?: string | null
  entityUri?: string | null
  capsPath?: string | null
  themeControl?: React.ReactNode
}) {
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
          <a
            href="/profile"
            role="menuitem"
            className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-muted-foreground transition hover:bg-muted hover:text-foreground"
          >
            <User aria-hidden="true" className="h-4 w-4" />
            Profile
          </a>
          {capsPath && (
            <a
              href={capsPath}
              role="menuitem"
              className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-muted-foreground transition hover:bg-muted hover:text-foreground"
            >
              <Lock aria-hidden="true" className="h-4 w-4" />
              My capabilities
            </a>
          )}
          {themeControl}
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

function entityCapsPath(entityUri?: string | null): string | null {
  if (!entityUri) return null

  const encoded = encodeURIComponent(entityUri)
  if (entityUri.includes("/agent/")) return `/identities/agents/${encoded}/caps`
  if (entityUri.includes("/user/")) return `/identities/users/${encoded}/caps`
  return null
}

type RenderContext = {
  layout: WorldLayout
  state: WorldState
  pushEvent?: (event: string, payload: unknown) => void
  onJoin: (sessionUri: string) => void
  onCreateSession: (
    shortName: string,
    templateName: string,
    socialwareRef?: string,
    options?: {
      role_slots?: Array<Record<string, unknown>>
      socialware_config_id?: string
      socialware_content_hash?: string
    },
  ) => void
  onPublishTemplate: (sessionUri: string, name: string) => void
  onForkConfig: (sessionUri: string) => void
  onCreateAgent: (agent: Record<string, unknown>) => void
  onCreateUser: (user: Record<string, unknown>) => void
  onSaveUserProfile: (payload: {user_uri: string; display_name: string; email: string}) => void
  onSetUserPassword: (payload: {user_uri: string; password: string}) => void
  onDeleteApiKey: (payload: {agent_uri: string; provider: string}) => void
  onDisableUser: (payload: {user_uri: string; reason: string}) => void
  onEnableUser: (payload: {user_uri: string}) => void
  onDeleteAgent: (agentUri: string) => void
  onConfigUpdate: (agentUri: string, key: string, patch: Record<string, unknown>) => void
  onConfigDeletePath: (agentUri: string, key: string, path: string[]) => void
  onPutApiKey: (payload: {agent_uri: string; provider: string; key: string}) => void
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
  onAssignRole: (sessionUri: string, member: string, roleName: string) => void
  onRemoveParticipant: (sessionUri: string, participant: string) => void
  onUninstallSocialware: (sessionUri: string, ref: string) => void
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
    case "sessions":
      return <SessionsTable key={component.id} state={context.state as SessionsState} onJoin={context.onJoin} onCreate={context.onCreateSession} />

    case "conversation":
      return (
        <Conversation
          key={component.id}
          // Source 1 is owned by the floating toast in WorldApp. main's
          // inline sync card is hidden; source-2 messages[].error_card stays.
          state={{...context.state, dispatch_error: null}}
          pushEvent={context.pushEvent}
          onAddRoutingRule={context.onAddRoutingRule}
          onCreate={context.onCreateSession}
          onOpenPty={context.onOpenSessionPty}
          onRestartOrchestrator={context.onRestartOrchestrator}
          onSend={context.onChatSend}
          onSwitch={context.onSessionSwitch}
          onSwitchView={context.onSessionViewSwitch}
          onToggleRoutingRule={context.onToggleRoutingRule}
          onLoadOlder={context.onLoadOlder}
          onMarkDisplayed={context.onMarkDisplayed}
          onInvite={context.onInvite}
          onForkConfig={context.onForkConfig}
          onRemoveParticipant={context.onRemoveParticipant}
          onUninstallSocialware={context.onUninstallSocialware}
          onPtyInput={context.onPtyInput}
          onPtyResize={context.onPtyResize}
          onServerEvent={context.onServerEvent}
          onKanbanAction={context.onWorkspacePluginAction}
          onPublishTemplate={context.onPublishTemplate}
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

    case "overview":
      return <Overview key={component.id} state={context.state} />

    case "market":
      return (
        <MarketSurface
          key={component.id}
          state={context.state as MarketState}
          onAction={context.onWorkspacePluginAction}
        />
      )

    case "admin":
      return <AdminSurface key={component.id} state={{...context.state, component: component.type} as AdminState} onAction={context.onAdminAction} />

    case "workspace_plugins":
      return (
        <WorkspacePluginSurface
          key={component.id}
          state={{...context.state, component: component.type}}
          onAction={context.onWorkspacePluginAction}
        />
      )

    case "identities":
      return (
        <IdentitiesSurface
          key={component.id}
          state={{...context.state, component: component.type}}
          onCreateAgent={context.onCreateAgent}
          onCreateUser={context.onCreateUser}
          onSaveUserProfile={context.onSaveUserProfile}
          onDeleteApiKey={context.onDeleteApiKey}
          onSetUserPassword={context.onSetUserPassword}
          onDisableUser={context.onDisableUser}
          onEnableUser={context.onEnableUser}
          onDeleteAgent={context.onDeleteAgent}
          onConfigUpdate={context.onConfigUpdate}
          onConfigDeletePath={context.onConfigDeletePath}
          onPutApiKey={context.onPutApiKey}
        />
      )

    default: {
      // 插件页面：family key 命中 PLUGIN_PAGE_RENDERERS 时渲染注册组件；
      // 未注册 family 保持原 fail-closed throw（无兜底渲染）。
      const PluginPage = pluginPageRenderers[rendererFamily(component.type)]
      if (PluginPage) {
        return <PluginPage key={component.id} component={component} state={context.state} onAction={context.onWorkspacePluginAction} />
      }

      throw new Error(
        `world: no renderer for family ${JSON.stringify(SLOTS[component.type]?.renderer_family)} ` +
          `(slot ${JSON.stringify(component.type)})`,
      )
    }
  }
}

function navClass(path: string | undefined, href: string) {
  const currentPath = typeof window !== "undefined" ? window.location.pathname : path
  const active = isPrimaryNavActive(currentPath, href)

  return active
    ? "rounded-md bg-accent px-3 py-1.5 text-sm font-medium text-accent-foreground"
    : "rounded-md px-3 py-1.5 text-sm font-medium text-muted-foreground transition hover:bg-muted hover:text-foreground"
}

function navHref(href: string, state: WorldState) {
  return href === "/sessions" ? sessionChatHref(state) : href
}

function sessionChatHref(state: WorldState) {
  const sessionUri = state.session_uri || state.current_session_uri
  return sessionUri ? `/sessions?session=${encodeURIComponent(sessionUri)}` : "/sessions"
}

function handleWorldNavClick(
  event: React.MouseEvent<HTMLAnchorElement>,
  href: string,
  pushEvent?: WorldMountOptions["pushEvent"],
) {
  if (
    event.defaultPrevented ||
    event.button !== 0 ||
    event.metaKey ||
    event.ctrlKey ||
    event.shiftKey ||
    event.altKey ||
    !pushEvent
  ) {
    return
  }

  event.preventDefault()
  pushEvent?.("world:navigate", {to: href})
}

function pageTitle(component: string | undefined) {
  return pageTitleForComponent(component)
}
