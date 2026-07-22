const PRIMARY_NAV_ITEMS = [
  {label: "Chat", href: "/sessions"},
  {label: "Market", href: "/market"},
  {label: "Agents", href: "/identities/agents"},
  {label: "Manage", href: "/workspaces"},
  {label: "Overview", href: "/overview"},
]

export function primaryNavItems() {
  return PRIMARY_NAV_ITEMS.map((item) => ({...item}))
}

export function isPrimaryNavActive(path, href) {
  const currentPath = pathOnly(path)

  if (href === "/sessions") {
    // Chat is the default landing: `/` and `/sessions` both highlight Chat.
    return currentPath === "/" || currentPath === "/sessions"
  }

  if (href === "/overview") {
    return currentPath === "/overview"
  }

  if (href === "/market") {
    return currentPath === "/market"
  }

  if (href === "/identities/agents") {
    return currentPath === "/identities" || currentPath.startsWith("/identities/")
  }

  if (href === "/workspaces") {
    return (
      currentPath === "/workspaces" ||
      currentPath.startsWith("/workspaces/") ||
      currentPath === "/plugins" ||
      currentPath.startsWith("/plugins/") ||
      currentPath === "/admin" ||
      currentPath.startsWith("/admin/")
    )
  }

  return currentPath === href
}

export function sectionRoot(path) {
  const currentPath = pathOnly(path)

  if (currentPath === "/") return null
  if (currentPath === "/sessions") return {label: "Chat", href: "/sessions"}
  if (currentPath === "/market") return {label: "Market", href: "/market"}
  if (currentPath.startsWith("/identities")) return {label: "Agents", href: "/identities/agents"}
  if (
    currentPath.startsWith("/admin") ||
    currentPath.startsWith("/workspaces") ||
    currentPath.startsWith("/plugins")
  ) {
    return {label: "Manage", href: "/workspaces"}
  }

  return null
}

export function pageTitleForComponent(component) {
  switch (component) {
    case "overview":
      return "Overview"
    case "market":
      return "Market"
    case "sessions_table":
    case "conversation":
      return "Chat"
    case "identities":
      return "Agents"
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
    case "workspace_template_new":
      return "New template"
    case "plugins":
      return "Plugins"
    case "profile":
      return "Profile"
    case "auto_derive":
      return "Auto derive"
    case "feishu_bindings":
      return "Feishu bindings"
    default:
      return "Chat"
  }
}

function pathOnly(path) {
  if (typeof path !== "string" || path.length === 0) return "/"
  return path.split(/[?#]/, 1)[0] || "/"
}
