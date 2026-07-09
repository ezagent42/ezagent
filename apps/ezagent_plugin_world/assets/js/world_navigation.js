const WORLD_ROUTE_PATTERNS = [
  /^\/$/,
  /^\/sessions$/,
  /^\/identities$/,
  /^\/identities\/users$/,
  /^\/identities\/agents$/,
  /^\/identities\/agents\/new$/,
  /^\/identities\/(?:users|agents)\/[^/]+\/caps$/,
  /^\/identities\/agents\/[^/]+(?:\/api-keys|\/config|\/extensions|\/terminal)?$/,
  /^\/workspaces$/,
  /^\/workspaces\/[^/]+\/templates\/new$/,
  /^\/workspaces\/[^/]+$/,
  /^\/plugins$/,
  /^\/plugins\/feishu\/bindings$/,
  /^\/plugins\/kanban(?:\/[^/]+)?$/,
  /^\/plugins\/auto\/[^/]+(?:\/[^/]+)?$/,
  /^\/profile$/,
  /^\/admin$/,
  /^\/admin\/(?:logs|registry|snapshots|templates|caps|settings|routing)$/,
  /^\/admin\/audit\/authz$/,
  /^\/admin\/sessions\/[^/]+\/external_mirror$/,
]

export function worldNavigationTarget(event, root, currentHref = window.location.href) {
  if (!shouldHandleClick(event)) return null

  const anchor = event.target?.closest?.("a[href]")
  if (!anchor || (root && !root.contains(anchor))) return null
  if (anchor.target && anchor.target !== "_self") return null
  if (anchor.hasAttribute?.("download")) return null

  const rawHref = anchor.getAttribute("href")
  if (!rawHref || rawHref === "#" || rawHref.startsWith("#")) return null

  let url
  let current

  try {
    url = new URL(rawHref, currentHref)
    current = new URL(currentHref)
  } catch (_error) {
    return null
  }

  if (url.origin !== current.origin) return null
  if (!isWorldRoutePath(url.pathname)) return null

  return `${url.pathname}${url.search}`
}

function shouldHandleClick(event) {
  return (
    !event.defaultPrevented &&
    event.button === 0 &&
    !event.metaKey &&
    !event.ctrlKey &&
    !event.shiftKey &&
    !event.altKey
  )
}

function isWorldRoutePath(pathname) {
  return WORLD_ROUTE_PATTERNS.some((pattern) => pattern.test(pathname))
}
