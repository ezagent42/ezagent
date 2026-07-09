import React from "react"
import {BadgeCheck, Boxes, Cable, ChevronRight, Layers, Pencil, Plug, Plus, Save, Trash2, UserRound, X} from "lucide-react"

import {Button, EmptyState, Input, Stat} from "./ui/primitives"

type DataRow = Record<string, unknown>

export type WorkspacePluginState = {
  bindings?: DataRow[]
  auto_derive_notice?: string | null
  caps_count?: number
  caps_path?: string | null
  component?: string
  detail?: DataRow
  detail_error?: string
  display_name?: string | null
  editing_display_name?: boolean
  entity_options?: unknown[]
  entity_uri?: string | null
  error?: string
  focus_slug?: string | null
  instances?: DataRow[]
  kind?: string | null
  members?: string[]
  name?: string
  not_found?: boolean
  path?: string
  plugins?: DataRow[]
  routing_rules?: DataRow[]
  session_templates?: DataRow[]
  template_error?: string | null
  template_mode?: string | null
  template_notice?: string | null
  title?: string
  uri?: string | null
  workspaces?: DataRow[]
  workspace_uri?: string | null
}

// Shared shadcn token classes (consistent with the admin/sessions/identities clusters).
const surfaceClass = "space-y-4 rounded-lg border border-border bg-card p-5 text-card-foreground"
const subsectionClass = "space-y-3"
const tableWrapClass = "overflow-x-auto rounded-md border border-border"
const tableClass = "w-full border-collapse text-sm"
const theadClass = "bg-muted/50 text-muted-foreground"
const tbodyClass = "divide-y divide-border"
const thClass = "px-3 py-2 text-left font-medium"
const tdClass = "px-3 py-2 align-top"
const rowClass = "hover:bg-muted/30"
const uriClass = "block w-fit rounded-md border border-border bg-muted/50 px-2 py-1 font-mono text-xs text-muted-foreground"
const codeClass = "font-mono text-xs text-muted-foreground"
const iconButtonClass =
  "inline-flex h-8 w-8 items-center justify-center rounded-md border border-border text-muted-foreground transition hover:bg-muted hover:text-foreground"
const actionLinkClass =
  "inline-flex w-fit items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground transition hover:opacity-90"
const fieldLabelClass = "grid gap-1 text-xs font-medium text-muted-foreground"
const selectClass =
  "h-9 rounded-md border border-input bg-background px-3 text-sm text-foreground outline-none transition focus:border-ring focus:ring-2 focus:ring-ring/30"

export function WorkspacePluginSurface({
  state,
  onAction = () => undefined,
}: {
  state: WorkspacePluginState
  onAction?: (action: string, args: Record<string, unknown>) => void
}) {
  if (state.component === "profile") return <Profile state={state} onAction={onAction} />

  let content: React.ReactNode

  switch (state.component) {
    case "workspace_detail":
    case "workspace_template_new":
      content = <WorkspaceDetail state={state} onAction={onAction} />
      break
    case "plugins":
      content = <Plugins state={state} />
      break
    case "auto_derive":
      content = <AutoDerive state={state} onAction={onAction} />
      break
    case "feishu_bindings":
      content = <FeishuBindings state={state} onAction={onAction} />
      break
    default:
      content = <Workspaces state={state} />
  }

  return (
    <ManageFrame active={manageActiveFor(state.component)} title={state.title || "Manage"}>
      {content}
    </ManageFrame>
  )
}

const MANAGE_ITEMS: Array<{key: string; label: string; href: string; hint: string}> = [
  {key: "workspace", label: "Workspace", href: "/workspaces", hint: "members, templates, routing"},
  {key: "plugins", label: "Plugins", href: "/plugins", hint: "routes, flavors, installed apps"},
  {key: "integrations", label: "Integrations", href: "/plugins/feishu/bindings", hint: "Feishu, mirrors, connectors"},
  {key: "admin", label: "Admin", href: "/admin", hint: "runtime and registry"},
  {key: "access", label: "Access", href: "/admin/caps", hint: "caps and authz audit"},
  {key: "system", label: "System", href: "/admin/settings", hint: "SMTP, routing, diagnostics"},
]

export function ManageFrame({
  active,
  title,
  children,
}: {
  active: string
  title: string
  children: React.ReactNode
}) {
  return (
    <section className="grid h-full min-h-0 overflow-hidden border-y border-border bg-background text-foreground lg:grid-cols-[232px_minmax(0,1fr)]" data-world-manage-layout>
      <aside className="min-h-0 overflow-y-auto border-b border-border bg-card p-3 lg:border-b-0 lg:border-r" aria-label="Manage sections">
        <div className="mb-3 px-1">
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Manage</p>
          <h2 className="text-sm font-semibold text-foreground">{title}</h2>
        </div>
        <nav className="grid gap-1 manage-nav">
          {MANAGE_ITEMS.map((item) => {
            const selected = item.key === active
            return (
              <a
                key={item.key}
                href={item.href}
                aria-current={selected ? "page" : undefined}
                className={
                  selected
                    ? "rounded-md border border-primary/30 bg-accent/70 px-3 py-2 text-sm font-medium text-accent-foreground"
                    : "rounded-md border border-transparent px-3 py-2 text-sm font-medium text-muted-foreground transition hover:border-border hover:bg-muted hover:text-foreground"
                }
              >
                <span className="block text-foreground">{item.label}</span>
                <span className="mt-0.5 block text-xs font-normal text-muted-foreground">{item.hint}</span>
              </a>
            )
          })}
        </nav>
      </aside>
      <main className="min-h-0 overflow-y-auto p-4">{children}</main>
    </section>
  )
}

function manageActiveFor(component?: string) {
  if (component === "plugins" || component === "auto_derive") return "plugins"
  if (component === "feishu_bindings") return "integrations"
  return "workspace"
}

function Workspaces({state}: {state: WorkspacePluginState}) {
  const rows = state.workspaces || []

  return (
    <section className={surfaceClass} data-world-component="workspaces_list">
      <Header eyebrow="Workspace" title="Workspaces" icon={<Boxes className="h-4 w-4" />} />
      <div className={tableWrapClass}>
        <table className={tableClass} id="world-workspaces-table">
          <thead className={theadClass}>
            <tr>
              <th className={thClass}>Name / URI</th>
              <th className={thClass}>Members</th>
              <th className={thClass}>Templates</th>
              <th className={thClass}>Rules</th>
              <th className={thClass}>Live</th>
            </tr>
          </thead>
          <tbody className={tbodyClass}>
            {rows.map((row) => (
              <tr key={String(row.uri || row.name)} className={rowClass}>
                <td className={tdClass}>
                  <strong className="block text-foreground">
                    <a className="hover:underline" href={String(row.detail_path || "#")}>
                      {String(row.name || row.uri)}
                    </a>
                  </strong>
                  <code className={codeClass}>{String(row.uri || "")}</code>
                </td>
                <td className={tdClass}>{String(row.members_count ?? 0)}</td>
                <td className={tdClass}>{String(row.templates_count ?? 0)}</td>
                <td className={tdClass}>{String(row.routing_rules_count ?? 0)}</td>
                <td className={tdClass}>{row.live ? "live" : "down"}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {rows.length === 0 && <EmptyState label="No visible workspaces." />}
      </div>
    </section>
  )
}

function WorkspaceDetail({
  state,
  onAction,
}: {
  state: WorkspacePluginState
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
  if (state.not_found) {
    return (
      <section className={surfaceClass} data-world-component="workspace_detail">
        <Header eyebrow="Workspace" title="Workspace not found" icon={<Boxes className="h-4 w-4" />} />
        <p className="text-sm text-muted-foreground">{String(state.name || state.path || "")}</p>
      </section>
    )
  }

  const creatingTemplate = state.component === "workspace_template_new" || state.template_mode === "new"
  const templateNewPath = workspaceTemplateNewPath(String(state.name || "system"))

  if (creatingTemplate) {
    return (
      <section className={surfaceClass} data-world-component="workspace_template_new">
        <Header eyebrow="Template" title="New template" icon={<Layers className="h-4 w-4" />} />
        <code className={uriClass}>{state.uri}</code>
        <SessionTemplatePanel state={state} onAction={onAction} focused />
      </section>
    )
  }

  return (
    <section className={surfaceClass} data-world-component="workspace_detail">
      <Header eyebrow="Workspace" title={String(state.name || "Workspace")} icon={<Boxes className="h-4 w-4" />} />
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat icon={<UserRound className="h-4 w-4" />} label="Members" value={(state.members || []).length} />
        <Stat icon={<Layers className="h-4 w-4" />} label="Templates" value={(state.session_templates || []).length} />
        <Stat icon={<Cable className="h-4 w-4" />} label="Routing rules" value={(state.routing_rules || []).length} />
      </div>
      <code className={uriClass}>{state.uri}</code>
      <a className={actionLinkClass} href={templateNewPath} data-world-template-new-entry>
        <Plus size={16} />
        New template
      </a>
      <section className={subsectionClass} data-world-component="workspace-members">
        <Header eyebrow="List" title="Members" compact />
        <div className="space-y-1">
          {(state.members || []).map((member) => (
            <div className="flex items-center justify-between gap-2 rounded-md border border-border bg-background px-2 py-1.5" key={member}>
              <code className={codeClass}>{member}</code>
              <button
                className={iconButtonClass}
                type="button"
                title="Remove member"
                onClick={() => onAction("workspace.member.remove", {member_uri: member})}
              >
                <Trash2 size={16} />
              </button>
            </div>
          ))}
          {(state.members || []).length === 0 && <EmptyState label="No entries." />}
        </div>
      </section>
      <SessionTemplatePanel state={state} onAction={onAction} />
      <DataTable component="workspace-routing" title="Routing rules" rows={state.routing_rules || []} nested />
    </section>
  )
}

function SessionTemplatePanel({
  state,
  onAction,
  focused = false,
}: {
  state: WorkspacePluginState
  onAction: (action: string, args: Record<string, unknown>) => void
  focused?: boolean
}) {
  const [name, setName] = React.useState("")
  const [description, setDescription] = React.useState("")
  const [socialwareEnabled, setSocialwareEnabled] = React.useState(false)
  const [webAnonAccess, setWebAnonAccess] = React.useState(false)
  const [roleName, setRoleName] = React.useState("orchestrator")
  const [entityFill, setEntityFill] = React.useState<"agent" | "human">("agent")
  const [recipe, setRecipe] = React.useState("orchestrator")
  const [flavor, setFlavor] = React.useState("cc")
  const socialwareName = `${name.trim() || "socialware"}-app`

  return (
    <section
      className={subsectionClass}
      data-world-component="workspace-templates"
      data-world-template-new-entry={focused ? "true" : undefined}
    >
      <Header eyebrow="Config" title={focused ? "New template" : "Session templates"} compact />
      {state.template_notice && <p className="text-sm text-emerald-600 dark:text-emerald-400">{state.template_notice}</p>}
      {state.template_error && <p className="text-sm text-destructive">{state.template_error}</p>}
      <form
        id="world-session-template-form"
        className="grid gap-3 sm:grid-cols-2"
        onSubmit={(event) => {
          event.preventDefault()
          const role = {roleName, fill: entityFill, recipe, flavor}
          const socialware = socialwareEnabled ? buildSocialwareDefinition({socialwareName, webAnonAccess, role}) : null
          const template: Record<string, unknown> = {
            name: name.trim(),
            description,
          }

          if (socialware) {
            template.installs = [socialwareName]
            template.socialware = socialware
          }

          onAction("workspace.template.save", {
            template,
          })
        }}
      >
        <label className={fieldLabelClass} htmlFor="world-session-template-name">
          Name
          <Input
            id="world-session-template-name"
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="public-demo"
          />
        </label>
        <label className={fieldLabelClass} htmlFor="world-session-template-description">
          Description
          <Input
            id="world-session-template-description"
            value={description}
            onChange={(event) => setDescription(event.target.value)}
            placeholder="Public customer-facing session"
          />
        </label>
        <label className="flex items-center gap-2 text-sm text-foreground" htmlFor="world-session-template-socialware-enabled">
          <input
            id="world-session-template-socialware-enabled"
            type="checkbox"
            checked={socialwareEnabled}
            onChange={(event) => {
              setSocialwareEnabled(event.target.checked)
              if (!event.target.checked) setWebAnonAccess(false)
            }}
          />
          <span>Socialware app</span>
        </label>
        {socialwareEnabled && (
          <div className="grid gap-3 rounded-md border border-border bg-background p-3 sm:col-span-2" data-world-template-role-config>
            <Header eyebrow="Role" title="Role and Entity" compact />
            <label className={fieldLabelClass} htmlFor="world-session-template-role-name">
              Role
              <Input
                id="world-session-template-role-name"
                value={roleName}
                onChange={(event) => setRoleName(event.target.value)}
                placeholder="orchestrator"
              />
            </label>
            <label className={fieldLabelClass} htmlFor="world-session-template-role-entity">
              Entity
              <select
                id="world-session-template-role-entity"
                className={selectClass}
                value={entityFill}
                onChange={(event) => setEntityFill(event.target.value === "human" ? "human" : "agent")}
              >
                <option value="agent">Agent</option>
                <option value="human">Human</option>
              </select>
            </label>
            {entityFill === "agent" && (
              <>
                <label className={fieldLabelClass} htmlFor="world-session-template-role-recipe">
                  Recipe
                  <Input
                    id="world-session-template-role-recipe"
                    value={recipe}
                    onChange={(event) => setRecipe(event.target.value)}
                    placeholder="orchestrator"
                  />
                </label>
                <label className={fieldLabelClass} htmlFor="world-session-template-role-flavor">
                  Flavor
                  <Input
                    id="world-session-template-role-flavor"
                    value={flavor}
                    onChange={(event) => setFlavor(event.target.value)}
                    placeholder="cc"
                  />
                </label>
              </>
            )}
            <label className="flex items-center gap-2 text-sm text-foreground" htmlFor="world-session-template-web-anon-access">
              <input
                id="world-session-template-web-anon-access"
                type="checkbox"
                checked={webAnonAccess}
                onChange={(event) => setWebAnonAccess(event.target.checked)}
              />
              <span>Allow anonymous web access</span>
            </label>
          </div>
        )}
        <div className="sm:col-span-2">
          <Button variant="primary" type="submit">
            <Save size={16} />
            Save template
          </Button>
        </div>
      </form>
      <DataTable component="workspace-templates" title="Saved templates" rows={state.session_templates || []} nested />
    </section>
  )
}

type SocialwareRoleDraft = {
  roleName: string
  fill: "agent" | "human"
  recipe: string
  flavor: string
}

function buildSocialwareDefinition({
  socialwareName,
  webAnonAccess,
  role,
}: {
  socialwareName: string
  webAnonAccess: boolean
  role: SocialwareRoleDraft
}) {
  const roleName = role.roleName.trim() || "orchestrator"
  const publishPolicy = webAnonAccess ? "supervised" : "auto"
  const roles =
    role.fill === "human"
      ? [{role_name: roleName, fill: "human"}]
      : [
          {
            role_name: roleName,
            fill: "agent",
            recipe: role.recipe.trim() || roleName,
            flavor: role.flavor.trim() || "cc",
          },
        ]

  return {
    name: socialwareName,
    bases: ["Ezagent.ActionSet.Session", "Ezagent.ActionSet.Publisher.SessionImpl"],
    shape: ["Ezagent.ActionSet.Turn", "Ezagent.ActionSet.Surface"],
    roles: roles,
    routing_rules: [
      {
        matcher: {type: "always"},
        receivers: [roleName],
        rule_set: "default",
        position: 0,
        prompt_template_ref: "answer",
      },
    ],
    prompt_templates: {
      answer: "Answer from the socialware knowledge and session context.",
    },
    legends: {
      default: {
        member_set: [roleName],
        bound_rule_set: "default",
        fold: false,
      },
    },
    adapters: [
      {
        adapter_id: "web_feed",
        role: webAnonAccess ? "customer" : "internal",
        config: {},
      },
    ],
    visibility_policy: {
      publish_policy: publishPolicy,
      web_anon_access: webAnonAccess,
    },
  }
}

function workspaceTemplateNewPath(workspaceName: string) {
  return `/workspaces/${encodeURIComponent(workspaceName)}/templates/new`
}

function Plugins({state}: {state: WorkspacePluginState}) {
  const rows = state.plugins || []

  return (
    <section className={surfaceClass} data-world-component="plugins">
      <Header eyebrow="Plugins" title="Installed plugins" icon={<Plug className="h-4 w-4" />} />
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {rows.map((plugin) => {
          const href = plugin.config_path ? String(plugin.config_path) : null
          const status = pluginSurfaceStatus(plugin)
          const clickable = href && status !== "route gap"
          const key = String(plugin.slug || plugin.name)
          const focused = state.focus_slug === plugin.slug
          const body = (
            <>
              <div className="flex items-start justify-between gap-2">
                <div className="font-semibold text-foreground">{String(plugin.name || plugin.slug)}</div>
                {clickable && <ChevronRight className="h-4 w-4 shrink-0 text-muted-foreground" aria-hidden="true" />}
              </div>
              <p className="text-sm text-muted-foreground">{String(plugin.description || "")}</p>
              <div className="flex items-center gap-2 text-xs text-muted-foreground">
                <code className={codeClass}>{String(plugin.version || "dev")}</code>
                <span className={status === "route gap" ? "text-amber-600 dark:text-amber-300" : href ? "text-primary" : ""}>
                  {status}
                </span>
              </div>
              {href && <div className="route-line truncate font-mono text-xs text-muted-foreground">{href}</div>}
            </>
          )

          return clickable ? (
            <a
              key={key}
              href={href}
              data-world-plugin-card
              data-world-plugin-status={status}
              className={[
                "block space-y-2 rounded-md border bg-background p-3 transition hover:border-primary/50 hover:bg-muted/40",
                focused ? "border-primary/60" : "border-border",
              ].join(" ")}
            >
              {body}
            </a>
          ) : (
            <article
              key={key}
              data-world-plugin-card
              data-world-plugin-status={status}
              className={[
                "space-y-2 rounded-md border bg-background p-3 opacity-75",
                focused ? "border-primary/60" : "border-border",
              ].join(" ")}
            >
              {body}
            </article>
          )
        })}
        {rows.length === 0 && <EmptyState label="No plugins registered." />}
      </div>
      <section className={subsectionClass} data-world-plugin-surface-table>
        <Header eyebrow="Matrix" title="Config surfaces" compact />
        <div className={tableWrapClass}>
          <table className={tableClass}>
            <thead className={theadClass}>
              <tr>
                <th className={thClass}>Plugin</th>
                <th className={thClass}>Surface</th>
                <th className={thClass}>Target</th>
                <th className={thClass}>Label</th>
              </tr>
            </thead>
            <tbody className={tbodyClass}>
              {rows.map((plugin) => (
                <tr key={String(plugin.slug || plugin.name)} className={rowClass}>
                  <td className={tdClass}>{String(plugin.slug || plugin.name)}</td>
                  <td className={tdClass}>{pluginSurfaceStatus(plugin)}</td>
                  <td className={tdClass}><code className={codeClass}>{String(plugin.config_path || "—")}</code></td>
                  <td className={tdClass}>{String(plugin.config_label || "—")}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {rows.length === 0 && <EmptyState label="No plugin surfaces." />}
        </div>
      </section>
    </section>
  )
}

function pluginSurfaceStatus(plugin: DataRow): string {
  const slug = String(plugin.slug || "")
  const path = typeof plugin.config_path === "string" ? plugin.config_path : ""

  if (slug === "kb" && path === "/plugins/kb") return "route gap"
  if (path.startsWith("/identities?filter=agent:")) return "flavor"
  if (path) return "route"
  return "no config"
}

function Profile({
  state,
  onAction,
}: {
  state: WorkspacePluginState
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
  const [displayName, setDisplayName] = React.useState(state.display_name || "")

  React.useEffect(() => {
    setDisplayName(state.display_name || "")
  }, [state.display_name])

  return (
    <section className={surfaceClass} data-world-component="profile">
      <Header eyebrow="Profile" title={state.display_name || "Profile"} icon={<UserRound className="h-4 w-4" />} />
      <code className={uriClass}>{state.entity_uri}</code>
      {state.editing_display_name ? (
        <form
          id="world-display-name-form"
          className="flex flex-wrap items-end gap-3"
          onSubmit={(event) => {
            event.preventDefault()
            onAction("profile.display_name.save", {display_name: displayName})
          }}
        >
          <label className={fieldLabelClass}>
            Display name
            <Input value={displayName} onChange={(event) => setDisplayName(event.target.value)} />
          </label>
          <button className={iconButtonClass} type="submit" title="Save display name">
            <Save size={16} />
          </button>
          <button
            className={iconButtonClass}
            type="button"
            title="Cancel"
            onClick={() => onAction("profile.display_name.cancel", {})}
          >
            <X size={16} />
          </button>
        </form>
      ) : (
        <Button id="world-edit-display-name" type="button" onClick={() => onAction("profile.display_name.edit", {})}>
          <Pencil size={16} />
          Edit display name
        </Button>
      )}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat icon={<BadgeCheck className="h-4 w-4" />} label="Capabilities" value={state.caps_count || 0} />
      </div>
      {state.caps_path && (
        <a className={actionLinkClass} href={state.caps_path}>
          View caps
        </a>
      )}
    </section>
  )
}

function AutoDerive({
  state,
  onAction,
}: {
  state: WorkspacePluginState
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
  if (state.detail || state.detail_error) {
    const cascade = (state.detail?.credential_cascade || null) as Record<string, unknown> | null

    return (
      <section className={surfaceClass} data-world-component="auto_derive">
        <Header eyebrow="Auto derive" title={`Kind ${state.kind || "unknown"}`} icon={<Layers className="h-4 w-4" />} />
        {state.detail_error && <p className="text-sm text-destructive">{state.detail_error}</p>}
        {state.auto_derive_notice && <p className="text-sm text-emerald-600 dark:text-emerald-400">{String(state.auto_derive_notice)}</p>}
        {cascade && <CredentialCascadePanel cascade={cascade} onAction={onAction} />}
        {state.detail && (
          <pre className="overflow-x-auto rounded-md border border-border bg-muted/40 p-3 text-xs text-muted-foreground">
            {JSON.stringify(state.detail, null, 2)}
          </pre>
        )}
      </section>
    )
  }

  return <DataTable component="auto_derive" title={`Kind ${state.kind || "unknown"}`} rows={state.instances || []} />
}

function FeishuBindings({
  state,
  onAction,
}: {
  state: WorkspacePluginState
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
  const [openId, setOpenId] = React.useState("")
  const [userUri, setUserUri] = React.useState("")
  const rows = state.bindings || []

  return (
    <section className={surfaceClass} data-world-component="feishu_bindings">
      <Header eyebrow="Feishu" title="User bindings" icon={<Cable className="h-4 w-4" />} />
      <form
        id="world-feishu-bind-form"
        className="flex flex-wrap items-end gap-3"
        onSubmit={(event) => {
          event.preventDefault()
          onAction("feishu.bind", {open_id: openId, user_uri: userUri})
          setOpenId("")
          setUserUri("")
        }}
      >
        <label className={fieldLabelClass}>
          open_id
          <Input value={openId} onChange={(event) => setOpenId(event.target.value)} />
        </label>
        <label className={fieldLabelClass}>
          user URI
          <Input list="world-feishu-entity-options" value={userUri} onChange={(event) => setUserUri(event.target.value)} />
        </label>
        <datalist id="world-feishu-entity-options">
          {(state.entity_options || []).map((option, index) => {
            const row = option as Record<string, unknown>
            return <option key={index} value={String(row.value || row.uri || "")} />
          })}
        </datalist>
        <Button variant="primary" type="submit">
          Bind
        </Button>
      </form>
      <section className={subsectionClass} data-world-component="feishu-bindings-table">
        <Header eyebrow="Table" title="Bindings" compact />
        <div className={tableWrapClass}>
          <table className={tableClass}>
            <thead className={theadClass}>
              <tr>
                <th className={thClass}>open_id</th>
                <th className={thClass}>user_uri</th>
                <th className={thClass}>bound_by</th>
                <th className={thClass}>bound_at</th>
                <th className={thClass} />
              </tr>
            </thead>
            <tbody className={tbodyClass}>
              {rows.map((row) => (
                <tr key={String(row.open_id)} className={rowClass}>
                  <td className={tdClass}><code className={codeClass}>{String(row.open_id || "")}</code></td>
                  <td className={tdClass}><code className={codeClass}>{String(row.user_uri || "")}</code></td>
                  <td className={tdClass}><code className={codeClass}>{String(row.bound_by || "")}</code></td>
                  <td className={tdClass}>{String(row.bound_at || "")}</td>
                  <td className={tdClass}>
                    <button
                      className={iconButtonClass}
                      type="button"
                      title="Unbind"
                      onClick={() => onAction("feishu.unbind", {open_id: String(row.open_id || "")})}
                    >
                      <Trash2 size={16} />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {rows.length === 0 && <EmptyState label="No rows." />}
        </div>
      </section>
    </section>
  )
}

function CredentialCascadePanel({
  cascade,
  onAction,
}: {
  cascade: Record<string, unknown>
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
  const form = (cascade.form || {}) as Record<string, unknown>
  const [sourceUri, setSourceUri] = React.useState(String(form.source_uri || ""))
  const [flavor, setFlavor] = React.useState(String(form.flavor || ""))
  const layerStack = (cascade.layer_stack || []) as Record<string, unknown>[]
  const grant = cascade.grant as Record<string, unknown> | null

  React.useEffect(() => {
    const next = (cascade.form || {}) as Record<string, unknown>
    setSourceUri(String(next.source_uri || ""))
    setFlavor(String(next.flavor || ""))
  }, [cascade.form])

  return (
    <section id="credential-cascade-panel" className={subsectionClass}>
      <Header eyebrow="Credentials" title="Credential cascade" compact />
      <KvGrid
        entries={[
          ["source", String(cascade.credential_source_uri || "none")],
          ["default", String(cascade.default_source_uri || "none")],
          ["flavor", String(cascade.flavor || "")],
        ]}
      />
      <SimpleList title="Layer stack" values={layerStack.map((row) => `${String(row.level)}: ${String(row.source || "not selected")}`)} />
      {grant ? (
        <div id="credential-grant-row" className="space-y-2">
          <KvGrid
            entries={[
              ["status", String(grant.status || "")],
              ["approved by", String(grant.approved_by || "")],
              ["version", String(grant.version || "")],
            ]}
          />
          <Button
            id="revoke-credential-grant"
            variant="danger"
            type="button"
            onClick={() => onAction("auto_derive.credential_grant.revoke", {agent_uri: String(cascade.agent_uri || "")})}
          >
            Revoke grant
          </Button>
        </div>
      ) : (
        <p className="text-sm text-muted-foreground">No credential grant for this agent.</p>
      )}
      <form
        id="set-default-source-form"
        className="flex flex-wrap items-end gap-3"
        onSubmit={(event) => {
          event.preventDefault()
          onAction("auto_derive.default_source.set", {
            default_source: {
              owner_uri: String(form.owner_uri || ""),
              workspace_uri: String(form.workspace_uri || ""),
              flavor,
              source_uri: sourceUri,
            },
          })
        }}
      >
        <label className={fieldLabelClass}>
          Flavor
          <Input value={flavor} onChange={(event) => setFlavor(event.target.value)} />
        </label>
        <label className={fieldLabelClass}>
          Source URI
          <Input value={sourceUri} onChange={(event) => setSourceUri(event.target.value)} />
        </label>
        <Button variant="primary" type="submit">
          Set default source
        </Button>
      </form>
    </section>
  )
}

function KvGrid({entries}: {entries: Array<[string, string]>}) {
  return (
    <div className="grid gap-2 sm:grid-cols-3">
      {entries.map(([label, value]) => (
        <div className="rounded-md border border-border bg-background p-2 text-xs" key={label}>
          <span className="block text-muted-foreground">{label}</span>
          <code className="font-mono text-foreground">{value}</code>
        </div>
      ))}
    </div>
  )
}

function DataTable({
  component,
  title,
  rows,
  nested = false,
}: {
  component: string
  title: string
  rows: DataRow[]
  nested?: boolean
}) {
  const columns = Array.from(new Set(rows.flatMap((row) => Object.keys(row)))).slice(0, 6)
  const cols = columns.length > 0 ? columns : ["value"]
  const containerClass = nested ? subsectionClass : surfaceClass

  return (
    <section className={containerClass} data-world-component={component}>
      <Header eyebrow="Table" title={title} compact={nested} />
      <div className={tableWrapClass}>
        <table className={tableClass}>
          <thead className={theadClass}>
            <tr>
              {cols.map((column) => (
                <th key={column} className={thClass}>
                  {column}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className={tbodyClass}>
            {rows.map((row, index) => (
              <tr key={index} className={rowClass}>
                {cols.map((column) => (
                  <td key={column} className={tdClass}>
                    <Cell value={columns.length > 0 ? row[column] : row} />
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
        {rows.length === 0 && <EmptyState label="No rows." />}
      </div>
    </section>
  )
}

function SimpleList({title, values}: {title: string; values: string[]}) {
  return (
    <section className={subsectionClass}>
      <Header eyebrow="List" title={title} compact />
      <div className="space-y-1">
        {values.map((value) => (
          <code className="block font-mono text-xs text-muted-foreground" key={value}>
            {value}
          </code>
        ))}
        {values.length === 0 && <EmptyState label="No entries." />}
      </div>
    </section>
  )
}

function Header({
  eyebrow,
  title,
  icon,
  compact = false,
}: {
  eyebrow: string
  title: string
  icon?: React.ReactNode
  compact?: boolean
}) {
  return (
    <div className="flex items-center justify-between gap-3">
      <div>
        <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{eyebrow}</p>
        <h2 className={compact ? "text-base font-semibold text-foreground" : "text-lg font-semibold text-foreground"}>{title}</h2>
      </div>
      {icon && <span className="text-muted-foreground">{icon}</span>}
    </div>
  )
}

function Cell({value}: {value: unknown}) {
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return <code className="rounded bg-muted px-1 py-0.5 text-xs text-foreground">{String(value)}</code>
  }

  if (value == null) return <span className="text-muted-foreground">null</span>

  return <code className="rounded bg-muted px-1 py-0.5 text-xs text-foreground">{JSON.stringify(value)}</code>
}
