import {Socket} from "phoenix"
import React, {useEffect, useMemo, useRef, useState} from "react"
import {createRoot} from "react-dom/client"
import {JsonRenderPage} from "./catalog_jsonrender.mjs"
import {PageShell} from "./theme_shell.mjs"
import {isValidTree} from "./catalog.mjs"
import {latestUnseenNavMessage} from "./viewer_nav.mjs"

// Round-1 preview: a placeholder body shown inside the AI frame so its design is
// visible for approval before real content is generated (round 2).
const SKELETON_PAGE = {
  type: "Stack",
  props: {direction: "vertical", gap: "xl", className: "p-8"},
  children: [
    {
      type: "Stack",
      props: {direction: "vertical", gap: "md"},
      children: [
        {type: "Heading", props: {text: "标题占位 · Your Headline", level: 1}},
        {type: "Text", props: {text: "这里是副标题占位 —— 真实内容将在下一步填充。"}},
        {type: "Button", props: {label: "开始", variant: "default"}},
      ],
    },
    {
      type: "Grid",
      props: {columns: 3, gap: "md"},
      children: [
        {type: "Card", props: {title: "特性一", description: "占位说明文字。"}},
        {type: "Card", props: {title: "特性二", description: "占位说明文字。"}},
        {type: "Card", props: {title: "特性三", description: "占位说明文字。"}},
      ],
    },
  ],
}

// Print the @json-render page data that actually drives the rendered page to the
// browser DevTools (F12) console — the "useful generated data" an internal reader wants
// to inspect. Logs the title, a per-type component count, and the full tree.
let prevHelloPage = null
let prevHelloPageJson = null

// A shallow structural diff (parallel position walk) that reports the NET change
// between two spec trees as human-readable lines — "what changed" for the console,
// instead of dumping the whole tree. Works whether the backend patched or fully
// regenerated (it shows the real difference either way).
function diffNodes(a, b, path, out) {
  if (!a && !b) return
  if (a && !b) return out.push(`− remove ${a.type || "?"} @ ${path}`)
  if (!a && b) return out.push(`+ add ${b.type || "?"} @ ${path}`)
  if (a.type !== b.type) return out.push(`⇄ replace @ ${path}: ${a.type} → ${b.type}`)
  const ap = a.props || {}
  const bp = b.props || {}
  for (const k of new Set([...Object.keys(ap), ...Object.keys(bp)])) {
    const av = JSON.stringify(ap[k])
    const bv = JSON.stringify(bp[k])
    if (av !== bv) out.push(`✎ ${a.type}.${k} @ ${path}: ${av ?? "∅"} → ${bv ?? "∅"}`)
  }
  const ac = a.children || []
  const bc = b.children || []
  for (let i = 0; i < Math.max(ac.length, bc.length); i++) {
    diffNodes(ac[i], bc[i], `${path}/${(b.type || "").toLowerCase()}[${i}]`, out)
  }
}

function logHelloPage(snapshot, source) {
  const page = snapshot && snapshot.page
  if (!page) return
  // The snapshot re-pushes on EVERY chat message (progress heartbeats, user
  // messages, …), but the PAGE usually hasn't changed. Skip those entirely so the
  // console shows ONLY real page edits — never the per-message "no change" noise.
  const pageJson = JSON.stringify(page)
  if (pageJson === prevHelloPageJson) return
  const prev = prevHelloPage
  prevHelloPage = page
  prevHelloPageJson = pageJson

  const counts = {}
  const walk = (n) => {
    if (Array.isArray(n)) return n.forEach(walk)
    if (n && typeof n === "object") {
      if (typeof n.type === "string") counts[n.type] = (counts[n.type] || 0) + 1
      walk(n.children || [])
    }
  }
  walk(page)
  const total = Object.values(counts).reduce((a, b) => a + b, 0)

  // Headline = WHAT CHANGED vs the previous page (the full tree is collapsed below).
  if (prev) {
    const changes = []
    diffNodes(prev, page, "page-root", changes)
    console.group(
      `%c[hello] ${changes.length} change(s)`,
      "color:#16a34a;font-weight:bold",
    )
    changes.forEach((c) => console.log("  " + c))
    console.groupEnd()
  } else {
    console.log(
      `%c[hello] page loaded%c · ${total} nodes · ${page?.props?.title ?? ""}`,
      "color:#16a34a;font-weight:bold",
      "color:inherit",
    )
  }

  // Full spec — collapsed (reference only) + globals for copy/inspect.
  console.groupCollapsed("%c  ↳ full spec / JSON / theme (reference)", "color:#888")
  console.log("byType:", counts)
  console.log("tree:", page)
  console.log("JSON:\n" + JSON.stringify(page, null, 2))
  if (snapshot.shell_css) console.log("theme CSS:\n" + snapshot.shell_css)
  console.log("globals: window.__helloSpec / __helloSnapshot — try copy(__helloSpec)")
  console.groupEnd()

  try {
    window.__helloSpec = page
    window.__helloSnapshot = snapshot
  } catch (_e) {}
}

// --- element selection (Lovable-style point-to-edit) ------------------------

// Capture a clicked page element as a model-readable "address": its kind
// (shadcn data-slot or tag), its visible text, and the nearest semantic section
// it sits in. The model uses this + the current spec to locate the node to edit.
function describeElement(el) {
  const text = (el.innerText || el.textContent || "").trim().replace(/\s+/g, " ").slice(0, 100)
  const kind = el.getAttribute("data-slot") || el.tagName.toLowerCase()
  let section = null
  let p = el
  while (p && p.classList && !p.classList.contains("page-root")) {
    for (const c of p.classList) {
      if (/^(nav|hero|section|feature|grid|pricing|plan|faq|cta|footer|sidebar|stat|card|toolbar|panel|list|row|header|title|price)/.test(c)) {
        section = c
        break
      }
    }
    if (section) break
    p = p.parentElement
  }
  return {kind, text, section}
}

function selectionLabel(sel) {
  if (!sel) return ""
  const t = sel.text ? `「${sel.text.slice(0, 22)}${sel.text.length > 22 ? "…" : ""}」` : ""
  return `${sel.kind}${t}`
}

// Prefix the user's request with the selected element so the model edits THAT
// node (or inserts relative to it), instead of guessing which one.
function selectionPrefix(sel) {
  const where = sel.section ? `, inside the .${sel.section} block` : ""
  return (
    `[The user selected an element on the page — a ${sel.kind}` +
    (sel.text ? ` showing «${sel.text}»` : "") +
    `${where}. Apply the request below to THAT specific element (edit it, or insert relative to it as asked):]\n`
  )
}

function boot(root) {
  const sessionUri = root.dataset.sessionUri
  // The caller-identity token (ChatFeedAuth) for the viewer — a minted read-only
  // anon-User or a signed-in member. It is BOTH the read identity and the
  // join/post actor; the channel verifies it to a principal and re-checks live
  // membership on every read. There is no separate identity-less session token.
  const token = root.dataset.token
  // The socket PATH and channel topic PREFIX are read from the mount element so
  // the SAME SPA serves both the external surface feed and the chat feed (P4
  // codex finding 3). Both default to the external-surface values.
  const socketPath = root.dataset.socketPath || "/socialware_external_socket"
  const topicPrefix = root.dataset.topicPrefix || "socialware:external"
  const delegationEndpoint = root.dataset.helloDelegationEndpoint || null
  const csrfToken = root.dataset.csrfToken || ""
  const reactRoot = createRoot(root)

  reactRoot.render(
    React.createElement(ViewerApp, {
      sessionUri,
      token,
      socketPath,
      topicPrefix,
      delegationEndpoint,
      csrfToken,
    })
  )
}

// The page chrome (input bar + json-render highlight) shows ONLY on the
// standalone public preview, NOT when the page is EMBEDDED as an iframe inside the
// world internal console (the reader just wants to SEE the rendered page there).
const IS_EMBEDDED = (() => {
  try {
    return window.self !== window.top
  } catch (_e) {
    return true
  }
})()

// Count messages authored by an AGENT (sender `entity://…/agent/…`). Used to tell
// a real reply apart from the member's OWN echoed message — only agent messages
// count as "a reply arrived" (clears the typing indicator + lights the unread dot).
function countAgents(msgs) {
  if (!Array.isArray(msgs)) return 0
  let n = 0
  for (const m of msgs) {
    if (m && typeof m.sender === "string" && m.sender.indexOf("/agent/") !== -1) n++
  }
  return n
}

// Execute a concierge navigation action on the page. The action is WHITELISTED
// server-side (type ∈ switch_tab/scroll_to/open_url), so this only ever does one
// of these three safe, local things.
function execNav(nav) {
  if (!nav || typeof nav !== "object") return
  const value = nav.value ? String(nav.value) : ""
  if (!value) return
  if (nav.type === "switch_tab") {
    window.dispatchEvent(new CustomEvent("jr-tab-switch", {detail: {value}}))
  } else if (nav.type === "open_url") {
    window.open(value, "_blank", "noopener,noreferrer")
  } else if (nav.type === "scroll_to") {
    const el = document.querySelector("." + value) || document.getElementById(value)
    if (el && el.scrollIntoView) el.scrollIntoView({behavior: "smooth", block: "start"})
  }
}

function latestKanbanReceipt(messages) {
  if (!Array.isArray(messages)) return null
  for (let i = messages.length - 1; i >= 0; i--) {
    const nav = messages[i] && messages[i].nav
    if (nav && nav.kind === "hello_kanban_receipt") return nav
  }
  return null
}

function kanbanStatusLabel(status) {
  switch (String(status || "unknown")) {
    case "unassigned": return "待派"
    case "claimed": return "已认领"
    case "doing": return "进行中"
    case "done": return "已完成"
    default: return "处理中"
  }
}

function ViewerApp({sessionUri, token, socketPath, topicPrefix, delegationEndpoint, csrfToken}) {
  const [snapshot, setSnapshot] = useState(null)
  const [unauthorized, setUnauthorized] = useState(false)
  // Debug: highlight which parts of the page are json-render (vs the HTML frame).
  const [jrHighlight, setJrHighlight] = useState(false)
  // The bottom preview bar: whether the chat history panel is expanded, and a
  // ref to the live channel so the bar's join/post actions can push to it.
  const [chatOpen, setChatOpen] = useState(false)
  // Point-to-edit: `selectMode` arms element picking; `selected` holds the chosen
  // element's address (kind/text/section) to ride the next message.
  const [selectMode, setSelectMode] = useState(false)
  const [selected, setSelected] = useState(null)
  const channelRef = useRef(null)
  // Navigation actions (switch_tab / scroll_to / open_url): execute the newest
  // UNSEEN whitelisted message nav. Agent URIs are UUID-based, so role identity
  // must not be inferred from a URI name segment. Existing history is baselined
  // so only replies arriving after mount can move the page.
  const navigationSeen = useRef(null)
  // "Waiting for a reply" typing indicator; cleared only when a NEW agent message
  // arrives — NOT the member's own echoed message. `awaitBaseAgent` = the agent
  // message count captured at send time.
  const [awaiting, setAwaiting] = useState(false)
  const awaitTimer = useRef(null)
  const awaitBaseAgent = useRef(0)
  useEffect(() => {
    document.body.classList.toggle("jr-highlight", jrHighlight)
    return () => document.body.classList.remove("jr-highlight")
  }, [jrHighlight])

  // Execute the newest unseen whitelisted nav action on the page.
  useEffect(() => {
    const msgs = snapshot && Array.isArray(snapshot.chat) ? snapshot.chat : []
    if (navigationSeen.current === null) {
      navigationSeen.current = new Set(msgs.map((m) => m && m.id).filter(Boolean))
      return
    }
    const latest = latestUnseenNavMessage(msgs, navigationSeen.current)
    if (!latest) return
    navigationSeen.current.add(latest.id)
    execNav(latest.nav)
  }, [snapshot])

  // Clear the typing indicator once a NEW agent message arrives (agent count grows
  // past the send-time baseline) — the member's own echoed message never clears it.
  useEffect(() => {
    if (!awaiting) return
    const msgs = snapshot && Array.isArray(snapshot.chat) ? snapshot.chat : []
    if (countAgents(msgs) > awaitBaseAgent.current) setAwaiting(false)
  }, [snapshot, awaiting])

  useEffect(() => {
    const socket = new Socket(socketPath, {params: {session_uri: sessionUri, token}})
    socket.connect()

    const channel = socket.channel(`${topicPrefix}:${sessionUri}`, {})
    channelRef.current = channel
    channel
      .join()
      .receive("ok", ({snapshot}) => {
        logHelloPage(snapshot, "initial")
        setSnapshot(snapshot)
      })
      .receive("error", () => setUnauthorized(true))

    channel.on("snapshot", (snapshot) => {
      logHelloPage(snapshot, "update")
      setSnapshot(snapshot)
    })

    // Live revocation (e.g. an ex-member who LEFT a chat): the server pushes
    // `unauthorized` then closes the channel. Fail closed on the CLIENT too —
    // CLEAR the rendered snapshot so a revoked viewer cannot keep reading stale
    // content (codex P4 HIGH). Without this the browser would keep the last
    // authorized snapshot visible after the channel closes.
    channel.on("unauthorized", () => {
      setSnapshot(null)
      setUnauthorized(true)
    })

    // A channel close AFTER a successful join (the server `{:stop}` on
    // revocation, or a dropped connection) also fails closed. `leaving` guards
    // the INTENTIONAL close from the unmount cleanup below so it doesn't flip
    // an unmounting component into the unauthorized state.
    let leaving = false
    channel.onClose(() => {
      if (!leaving) {
        setSnapshot(null)
        setUnauthorized(true)
      }
    })

    return () => {
      leaving = true
      channelRef.current = null
      channel.leave()
      socket.disconnect()
    }
  }, [sessionUri, token, socketPath, topicPrefix])

  // Publish the server-derived viewer identity (logged_in / member / name) so the
  // json-render nav's auth button can reflect it. A catalog component can't see
  // this React state, so it reads `window.__ezViewer` + the `jr-viewer` event —
  // the SAME decoupling `jr-tab-switch` uses for the nav tabs.
  useEffect(() => {
    const v = (snapshot && snapshot.viewer) || {logged_in: false, member: false}
    window.__ezViewer = v
    window.dispatchEvent(new CustomEvent("jr-viewer", {detail: v}))
  }, [snapshot])

  // Element-picking mode: hover outlines the element under the cursor; a click
  // captures it as `selected` and exits. Capture-phase listeners so a click
  // selects instead of activating the underlying button/link.
  useEffect(() => {
    if (!selectMode) return
    document.body.classList.add("jr-selecting")
    let hovered = null
    const clear = () => {
      if (hovered) hovered.classList.remove("jr-hover")
      hovered = null
    }
    const inPage = (el) => el && el.closest && el.closest(".page-root")
    const onMove = (e) => {
      const el = inPage(e.target) ? e.target : null
      if (el === hovered) return
      clear()
      if (el && !el.classList.contains("page-root")) {
        el.classList.add("jr-hover")
        hovered = el
      }
    }
    const onClick = (e) => {
      if (!inPage(e.target)) return
      e.preventDefault()
      e.stopPropagation()
      setSelected(describeElement(e.target))
      setSelectMode(false)
    }
    document.addEventListener("mousemove", onMove, true)
    document.addEventListener("click", onClick, true)
    return () => {
      document.body.classList.remove("jr-selecting")
      clear()
      document.removeEventListener("mousemove", onMove, true)
      document.removeEventListener("click", onClick, true)
    }
  }, [selectMode])

  if (unauthorized) {
    return React.createElement(
      "div",
      {
        className: "mx-auto max-w-md py-16 text-center",
        "data-state": "unauthorized",
      },
      React.createElement(
        "div",
        {className: "rounded-md border border-destructive/40 bg-destructive/10 px-4 py-3 text-center text-destructive"},
        React.createElement("span", {className: "font-medium"}, "Unauthorized")
      )
    )
  }

  if (!snapshot) {
    return React.createElement(
      "div",
      {
        className: "flex flex-col items-center gap-3 py-24 text-muted-foreground",
        "data-state": "loading",
      },
      React.createElement("span", {className: "h-5 w-5 animate-spin rounded-full border-2 border-muted-foreground/30 border-t-muted-foreground"}),
      React.createElement("span", {className: "text-sm"}, "Loading")
    )
  }

  // Centered single-column reading width. The sw-customer-shell contract class
  // is kept (E2E asserts on it); Tailwind layout classes sit alongside.
  //
  // `data-catalog-valid` is a NON-destructive conformance signal: the approved
  // page is rendered regardless (the renderer fails closed per node), but a tree
  // that does not conform to the Zod catalog is flagged for observability/E2E.
  const page = snapshot.page
  const childCount = page && Array.isArray(page.children) ? page.children.length : 0
  const hasBody = childCount > 0
  let content

  // Two-round flow: ROUND 1 lands only the FRAME (snapshot.shell) with no body
  // yet. Show the frame WITH a placeholder skeleton in the slot so its design is
  // visible for approval. ROUND 2 fills the real json-render body.
  if (snapshot.shell) {
    // Legacy hybrid (AI HTML frame + json-render body in a [data-slot]).
    content = React.createElement(HybridPage, {
      shell: snapshot.shell,
      shellCss: snapshot.shell_css,
      page: hasBody ? page : SKELETON_PAGE,
    })
  } else if (hasBody) {
    // Pure shadcn page + AI-generated CSS theme: the whole page is a shadcn spec,
    // and `shell_css` is a sanitized plain-CSS theme designed for THIS page. No
    // HTML frame. The theme targets `.page` / `.page-root` / shadcn data-slots.
    content = React.createElement(PureThemePage, {page, themeCss: snapshot.shell_css})
  } else {
    // No page yet → clean empty state.
    content = React.createElement(
      "div",
      {
        className: "sw-customer-shell flex min-h-[60vh] w-full flex-col items-center justify-center gap-3 px-6 text-center text-muted-foreground",
        "data-catalog-valid": "true",
        "data-empty": "true",
      },
      React.createElement("p", {className: "text-base font-medium text-foreground/70"}, "还没有页面"),
      React.createElement("p", {className: "max-w-sm text-sm"}, "在聊天里描述你想要的页面,生成的页面会显示在这里。")
    )
  }

  // Viewer identity + actions for the fixed bottom preview bar. `snapshot.viewer`
  // (server-derived from the customer token) tells us whether the opener is
  // logged-in and a member; everything else stays read-only by construction.
  const viewer = snapshot.viewer || {logged_in: false, member: false}
  // The collaborative chat panel shows the FULL conversation (`snapshot.chat` —
  // every participant's messages), not the committed customer-delivery projection
  // (`snapshot.messages`). Fall back to `messages` if an older server omits chat.
  const messages = Array.isArray(snapshot.chat)
    ? snapshot.chat
    : Array.isArray(snapshot.messages)
      ? snapshot.messages
      : []
  const doJoin = () => {
    const ch = channelRef.current
    if (!ch) return
    ch.push("join", {})
      .receive("ok", () => console.log("%c[hello] joined ✓", "color:#16a34a"))
      .receive("error", (e) => console.warn("[hello] join failed:", e))
      .receive("timeout", () => console.warn("[hello] join timed out"))
  }
  const doPost = (text) => {
    const ch = channelRef.current
    if (!ch) return
    // If an element is selected, prepend its address so hello edits THAT node.
    const full = selected ? selectionPrefix(selected) + text : text
    ch.push("post", {text: full})
      .receive("error", (e) => console.warn("[hello] post failed:", e))
    setSelected(null)
    // Baseline the current agent-message count; the typing indicator clears only
    // when a NEW agent message pushes the count past this (not on our own echo).
    awaitBaseAgent.current = countAgents(messages)
    setAwaiting(true)
    window.clearTimeout(awaitTimer.current)
    awaitTimer.current = window.setTimeout(() => setAwaiting(false), 45000)
  }
  const doLogin = () => {
    const back = window.location.pathname + window.location.search
    window.location.href = "/login?return_to=" + encodeURIComponent(back)
  }

  return React.createElement(
    React.Fragment,
    null,
    React.createElement("style", {dangerouslySetInnerHTML: {__html: JR_HIGHLIGHT_CSS + PREVIEWBAR_CSS}}),
    content,
    !IS_EMBEDDED && awaiting
      ? React.createElement(
          "div",
          {className: "concierge-bubble concierge-loading", key: "cl", "aria-label": "正在回复"},
          React.createElement("span", {className: "typing-dot"}),
          React.createElement("span", {className: "typing-dot"}),
          React.createElement("span", {className: "typing-dot"}),
        )
      : null,
    IS_EMBEDDED
      ? null
      : React.createElement(PreviewBar, {
      viewer,
      sessionUri,
      messages,
      chatOpen,
      setChatOpen,
      onJoin: doJoin,
      onPost: doPost,
      onLogin: doLogin,
      selected,
      onClearSelection: () => setSelected(null),
      selectMode,
      onToggleSelect: () => {
        setSelectMode((v) => !v)
        setSelected(null)
      },
      jrHighlight,
      onToggleHighlight: () => setJrHighlight((v) => !v),
      delegationEndpoint,
      csrfToken,
    })
  )
}

// Highlight overlay: every json-render node carries `data-jr-type`; the HTML frame
// (nav/footer/background) has none, so toggling this clearly separates the two.
// The whole page IS json-render now (no HTML frame), so highlight the ENTIRE
// json-render tree: the `.page-root` (the spec root — labelled), EVERY element
// under it (layout containers like Stack/Grid render as plain divs with no
// `data-slot`, so they need a descendant rule), and the shadcn components
// (`[data-slot]`) a touch stronger. The old `[data-jr-type]` selector matched
// nothing — the shadcn renderer never emits it.
const JR_HIGHLIGHT_CSS = `
body.jr-highlight .page-root{outline:3px solid #d946ef;outline-offset:3px;position:relative}
body.jr-highlight .page-root::before{content:"json-render — whole page";position:absolute;top:0;left:0;background:#d946ef;color:#fff;font:600 10px/1 ui-monospace,monospace;padding:3px 5px;border-radius:0 0 4px 0;z-index:9999;pointer-events:none}
body.jr-highlight .page-root *{outline:1px solid rgba(217,70,239,.28);outline-offset:-1px}
body.jr-highlight [data-slot]{outline:1.5px solid rgba(217,70,239,.75);outline-offset:-1px}
`

// The fixed bottom-center preview bar — page chrome, NOT part of the generated
// json-render spec. It is the single interaction surface on the otherwise
// read-only public page: a glass input pill with an inner-right action button
// whose label/behaviour is driven by `viewer` (server-derived from the customer
// token), plus a chevron that expands the session chat history UPWARD.
//
//   not logged in        → "登录"  → /login (the page stays read-only)
//   logged in, not member→ "加入"  → channel push "join" (become a member)
//   logged in + member   → "发送"  → channel push "post" (== @hello, no manual @)
//
// Anon viewers are read-only BY CONSTRUCTION (the anon-User's caps deny
// chat.send), so a disabled input is the honest affordance, not a security gate.
function PreviewBar({viewer, sessionUri, messages, chatOpen, setChatOpen, onJoin, onPost, onLogin, selected, onClearSelection, selectMode, onToggleSelect, jrHighlight, onToggleHighlight, delegationEndpoint, csrfToken}) {
  const [draft, setDraft] = useState("")
  const instructionRef = useRef(null)
  const loggedIn = !!(viewer && viewer.logged_in)
  const member = loggedIn && !!viewer.member
  const receipt = latestKanbanReceipt(messages)

  useEffect(() => {
    const focusComposer = () => {
      if (instructionRef.current) {
        instructionRef.current.focus()
        instructionRef.current.scrollIntoView({behavior: "smooth", block: "center"})
      }
    }
    window.addEventListener("jr-composer-focus", focusComposer)
    return () => window.removeEventListener("jr-composer-focus", focusComposer)
  }, [])
  // Unread hint on the open-session button: the chat panel no longer expands
  // inline, so a new reply (from @hello / the concierge) lights a red dot to tell
  // the member to open the session. Baseline = the message count at mount (so the
  // already-loaded history is NOT counted as unread); a later increase lights it;
  // opening the session clears it. Only members get replies / can open.
  // Only an AGENT reply lights the unread dot — the member's OWN sent message must
  // not (that was the "red dot appears the instant I send" bug).
  const agentCount = countAgents(messages)
  const prevAgentCount = React.useRef(agentCount)
  const [unread, setUnread] = useState(false)
  React.useEffect(() => {
    if (member && agentCount > prevAgentCount.current) setUnread(true)
    prevAgentCount.current = agentCount
  }, [agentCount, member])
  const openSession = () => {
    setUnread(false)
    window.open("/sessions?session=" + encodeURIComponent(sessionUri), "_blank", "noopener,noreferrer")
  }
  const submit = () => {
    const t = draft.trim()
    if (!t || !member) return
    onPost(t)
    setDraft("")
  }

  let action
  if (!loggedIn) {
    action = delegationEndpoint
      ? React.createElement("button", {id: "hello-delegate-login", type: "submit", className: "previewbar-action", disabled: !draft.trim()}, "登录并交给 Kanban")
      : React.createElement("button", {type: "button", className: "previewbar-action", onClick: onLogin}, "登录")
  } else if (!member) {
    action = React.createElement("button", {type: "button", className: "previewbar-action", onClick: onJoin}, "加入")
  } else {
    action = React.createElement(
      "button",
      {type: "button", className: "previewbar-action", onClick: submit, disabled: !draft.trim()},
      "发送"
    )
  }

  const placeholder = !loggedIn
    ? delegationEndpoint ? "描述任务，登录后交给 Kanban" : "登录后参与"
    : !member
      ? "加入后可发言"
      : selected
        ? "想怎么改这个?"
        : "说点什么…"

  // When an element is selected, show a removable chip so the next message targets it.
  const chip =
    selected && member
      ? React.createElement(
          "div",
          {className: "previewbar-chip"},
          React.createElement("span", {className: "previewbar-chip-text"}, `已选中:${selectionLabel(selected)}`),
          React.createElement(
            "button",
            {type: "button", className: "previewbar-chip-x", onClick: onClearSelection, "aria-label": "取消选择"},
            "✕"
          )
        )
      : null

  const prompt = React.createElement(
    "form",
    {
      id: "hello-prompt-form",
      className: "previewbar",
      action: !loggedIn && delegationEndpoint ? delegationEndpoint : undefined,
      method: !loggedIn && delegationEndpoint ? "post" : undefined,
      onSubmit: member ? (event) => { event.preventDefault(); submit() } : undefined,
    },
      delegationEndpoint ? React.createElement("input", {type: "hidden", name: "session_uri", value: sessionUri}) : null,
      delegationEndpoint ? React.createElement("input", {type: "hidden", name: "_csrf_token", value: csrfToken}) : null,
      // Open the full session (world console conversation view) in a new tab —
      // NOT an inline panel. Enabled only for a joined member (login + join); an
      // anon/guest sees it disabled (their speak/join rules are unchanged).
      React.createElement(
        "button",
        {
          type: "button",
          className: "previewbar-toggle",
          disabled: !member,
          onClick: member ? openSession : undefined,
          title: member
            ? unread
              ? "有新消息 · Open session (new reply)"
              : "打开会话 · Open session (new tab)"
            : "登录并加入后可打开会话",
          "aria-label": "打开会话",
        },
        "↗",
        unread && member
          ? React.createElement("span", {className: "previewbar-dot", "aria-hidden": "true"})
          : null,
      ),
      React.createElement("input", {
        ref: instructionRef,
        className: "previewbar-input",
        name: "instruction",
        value: draft,
        disabled: !member && !(delegationEndpoint && !loggedIn),
        placeholder,
        onChange: (e) => setDraft(e.target.value),
        onKeyDown: (e) => {
          if (member && e.key === "Enter" && !e.nativeEvent.isComposing) {
            e.preventDefault()
            submit()
          }
        },
      }),
      member
        ? React.createElement(
            "button",
            {
              type: "button",
              className: "previewbar-select" + (selectMode ? " is-active" : ""),
              onClick: onToggleSelect,
              title: "点选页面任意元素,再描述要怎么改",
            },
            selectMode ? "选择中" : "选择"
          )
        : null,
      action,
      React.createElement(
        "button",
        {
          type: "button",
          className: "previewbar-hl" + (jrHighlight ? " is-on" : ""),
          onClick: onToggleHighlight,
          title: jrHighlight ? "隐藏 json-render 高亮" : "高亮 json-render 结构",
          "aria-label": "高亮 json-render",
        },
        "◐"
      )
  )

  return React.createElement(
    "div",
    {className: "previewbar-wrap", "data-viewer": member ? "member" : loggedIn ? "guest" : "anon"},
    chatOpen ? React.createElement(ChatPanel, {messages, onClose: () => setChatOpen(false)}) : null,
    chip,
    prompt,
    React.createElement(
      "div",
      {id: "hello-kanban-result", className: receipt ? "hello-kanban-result is-visible" : "hello-kanban-result", role: "status", "aria-live": "polite"},
      receipt
        ? React.createElement(
            React.Fragment,
            null,
            React.createElement("span", {id: "hello-published-board-status", className: "hello-kanban-result-kicker"}, `KANBAN · 已发布只读看板 · r${receipt.publication_revision || 1}`),
            React.createElement("span", {className: "hello-kanban-result-snapshot"}, "委派快照 · 非实时状态"),
            React.createElement("strong", {className: "hello-kanban-result-title"}, receipt.title || "Kanban task"),
            React.createElement("span", {className: "hello-kanban-result-status"}, kanbanStatusLabel(receipt.status)),
            React.createElement("code", {className: "hello-kanban-result-ref"}, `${receipt.board_uri || ""} · ${receipt.node_id || ""}`),
            React.createElement("span", {id: "hello-published-board-readonly", className: "hello-kanban-result-boundary"}, "访客接收后只读；修改仍由原 Kanban 管理"),
            receipt.live_board_url
              ? React.createElement("a", {className: "hello-kanban-result-link", href: receipt.live_board_url, target: "_blank", rel: "noreferrer"}, "在 World Kanban 查看实时进度 →")
              : null,
            React.createElement("a", {className: "hello-kanban-result-link is-secondary", href: receipt.value, target: "_blank", rel: "noreferrer"}, "接收只读看板"),
          )
        : null,
    ),
  )
}

// A live elapsed-seconds counter rendered next to the latest "⏳ …" progress line,
// so a long generation shows ticking time WITHOUT the server spamming a message per
// second. Resets per message (keyed by message id); unmounts when a newer message
// supersedes the progress line.
function ProgressTicker() {
  const [s, setS] = useState(0)
  useEffect(() => {
    const start = Date.now()
    const id = setInterval(() => setS(Math.floor((Date.now() - start) / 1000)), 1000)
    return () => clearInterval(id)
  }, [])
  return React.createElement("span", {className: "previewbar-tick"}, ` · ${s}s`)
}

function ChatPanel({messages, onClose}) {
  const bodyRef = useRef(null)
  const stickRef = useRef(true)

  // Auto-scroll to the newest message ONLY when the user is already near the
  // bottom; if they scrolled up to read history, leave them there.
  const onScroll = () => {
    const el = bodyRef.current
    if (el) stickRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 48
  }
  useEffect(() => {
    const el = bodyRef.current
    if (el && stickRef.current) el.scrollTop = el.scrollHeight
  }, [messages])

  return React.createElement(
    "div",
    {className: "previewbar-chat"},
    React.createElement(
      "div",
      {className: "previewbar-chat-head"},
      React.createElement("span", null, "会话"),
      React.createElement("button", {type: "button", className: "previewbar-chat-close", onClick: onClose, "aria-label": "收起"}, "✕")
    ),
    React.createElement(
      "div",
      {className: "previewbar-chat-body", ref: bodyRef, onScroll: onScroll},
      messages.length === 0
        ? React.createElement("p", {className: "previewbar-chat-empty"}, "还没有消息。")
        : messages.map((m, i) => {
            // The LAST message, if it is a "…"-terminated progress line, gets a
            // live ticker (the backend's `with_progress` lines end with an ellipsis).
            const live = i === messages.length - 1 && (m.text || "").endsWith("…")
            return React.createElement(
              "div",
              {key: m.id || i, className: "previewbar-msg"},
              m.sender ? React.createElement("span", {className: "previewbar-msg-who"}, shortSender(m.sender)) : null,
              React.createElement(
                "span",
                {className: "previewbar-msg-text"},
                m.text || "",
                live ? React.createElement(ProgressTicker, {key: "tick-" + (m.id || i)}) : null
              )
            )
          })
    )
  )
}

// entity://ws/user/alice → "alice" ; entity://ws/agent/hello_x → "hello".
function shortSender(uri) {
  const m = String(uri).match(/\/([^/]+)$/)
  const last = m ? m[1] : String(uri)
  return last.indexOf("hello_") === 0 ? "hello" : last
}

const PREVIEWBAR_CSS = `
.previewbar-wrap{position:fixed;left:50%;bottom:1.25rem;transform:translateX(-50%);z-index:60;width:min(40rem,calc(100vw - 1.5rem));display:flex;flex-direction:column;gap:.5rem;font-family:system-ui,-apple-system,"Segoe UI",sans-serif}
.previewbar{display:flex;align-items:center;gap:.5rem;padding:.4rem .45rem .4rem .65rem;border-radius:999px;background:rgba(255,255,255,.72);backdrop-filter:blur(20px) saturate(1.6);-webkit-backdrop-filter:blur(20px) saturate(1.6);border:1px solid rgba(255,255,255,.65);box-shadow:0 1px 0 rgba(255,255,255,.9) inset,0 16px 44px rgba(0,0,0,.16)}
.previewbar-toggle{position:relative;flex-shrink:0;width:2.1rem;height:2.1rem;border-radius:999px;border:none;background:rgba(0,0,0,.05);color:#444;cursor:pointer;font-size:.85rem;line-height:1;transition:background .15s}
.previewbar-toggle:hover:not(:disabled){background:rgba(0,0,0,.1)}
.previewbar-toggle:disabled{opacity:.4;cursor:not-allowed}
.previewbar-dot{position:absolute;top:.18rem;right:.18rem;width:.5rem;height:.5rem;border-radius:999px;background:#e5484d;box-shadow:0 0 0 2px rgba(255,255,255,.92)}
.concierge-bubble{position:fixed;left:50%;bottom:5.2rem;transform:translateX(-50%);z-index:61;max-width:min(34rem,calc(100vw - 2rem));padding:.7rem 1rem;border-radius:1rem;background:rgba(255,255,255,.94);backdrop-filter:blur(20px) saturate(1.6);-webkit-backdrop-filter:blur(20px) saturate(1.6);border:1px solid rgba(255,255,255,.7);box-shadow:0 12px 34px rgba(0,0,0,.16);font-size:.9rem;line-height:1.5;color:#1a1a1a;animation:cb-in .2s cubic-bezier(.16,1,.3,1)}
@keyframes cb-in{from{opacity:0;transform:translate(-50%,8px)}to{opacity:1;transform:translate(-50%,0)}}
.concierge-loading{display:flex;gap:.32rem;align-items:center;padding:.7rem 1.05rem}
.typing-dot{width:.42rem;height:.42rem;border-radius:999px;background:#9a9a9a;animation:typing 1.2s ease-in-out infinite}
.typing-dot:nth-child(2){animation-delay:.18s}
.typing-dot:nth-child(3){animation-delay:.36s}
@keyframes typing{0%,60%,100%{opacity:.28;transform:translateY(0)}30%{opacity:1;transform:translateY(-.18rem)}}
.previewbar-input{flex:1;min-width:0;border:none;background:transparent;outline:none;font-size:.95rem;color:#181818;height:2.4rem;padding:0 .25rem}
.previewbar-input:disabled{color:#8a8a8a;cursor:not-allowed}
.previewbar-input::placeholder{color:#9a9a9a}
.previewbar-action{flex-shrink:0;height:2.4rem;padding:0 1.25rem;border-radius:999px;border:none;background:#1c1c1c;color:#fff;font-weight:600;font-size:.88rem;cursor:pointer;transition:opacity .15s,transform .1s}
.previewbar-action:hover{opacity:.9}
.previewbar-action:active{transform:scale(.97)}
.previewbar-action:disabled{opacity:.38;cursor:default}
.previewbar-select{flex-shrink:0;height:2.4rem;padding:0 1.25rem;border-radius:999px;border:none;background:#1c1c1c;color:#fff;font-weight:600;font-size:.88rem;cursor:pointer;white-space:nowrap;transition:opacity .15s,transform .1s}
.previewbar-select:hover{opacity:.9}
.previewbar-select:active{transform:scale(.97)}
.previewbar-select.is-active{background:#52525b}
.previewbar-hl{flex-shrink:0;width:2.1rem;height:2.1rem;border-radius:999px;border:none;background:rgba(0,0,0,.05);color:#999;cursor:pointer;font-size:.9rem;line-height:1;transition:background .15s,color .15s}
.previewbar-hl:hover{background:rgba(0,0,0,.1);color:#555}
.previewbar-hl.is-on{background:#d946ef;color:#fff}
.jr-highlight-btn{position:fixed;top:2.75rem;right:.625rem;z-index:9999;width:1.75rem;height:1.75rem;display:inline-flex;align-items:center;justify-content:center;border-radius:.375rem;border:1px solid rgba(0,0,0,.1);background:rgba(255,255,255,.9);color:#444;box-shadow:0 1px 2px rgba(0,0,0,.06);backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);cursor:pointer;font-size:.95rem;line-height:1;transition:background .15s}
.jr-highlight-btn:hover{background:rgba(0,0,0,.05)}
.jr-highlight-btn.is-on{background:#d946ef;color:#fff;border-color:#d946ef}
.previewbar-chat{max-height:50vh;display:flex;flex-direction:column;border-radius:1.4rem;background:rgba(255,255,255,.86);backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);border:1px solid rgba(0,0,0,.06);box-shadow:0 16px 44px rgba(0,0,0,.16);overflow:hidden;animation:previewbar-rise .18s ease}
@keyframes previewbar-rise{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}
.previewbar-chat-head{display:flex;align-items:center;justify-content:space-between;padding:.65rem .95rem;border-bottom:1px solid rgba(0,0,0,.06);font-weight:600;font-size:.85rem;color:#444;flex-shrink:0}
.previewbar-chat-close{border:none;background:transparent;cursor:pointer;color:#999;font-size:.85rem;line-height:1}
.previewbar-chat-body{overflow-y:auto;padding:.8rem .95rem;display:flex;flex-direction:column;gap:.7rem}
.previewbar-chat-empty{color:#9a9a9a;font-size:.85rem;text-align:center;padding:1.2rem 0;margin:0}
.previewbar-msg{display:flex;flex-direction:column;gap:.12rem}
.previewbar-msg-who{font-size:.68rem;font-weight:700;color:#6d5cf0;text-transform:uppercase;letter-spacing:.03em}
.previewbar-msg-text{font-size:.9rem;line-height:1.5;color:#222;white-space:pre-wrap;word-break:break-word}
.previewbar-tick{color:#6d5cf0;font-weight:700;font-variant-numeric:tabular-nums}
body.jr-selecting,body.jr-selecting .page-root *{cursor:crosshair !important}
body.jr-selecting .previewbar-wrap,body.jr-selecting .previewbar-wrap *{cursor:auto !important}
.jr-hover{outline:2px solid #6366f1 !important;outline-offset:-1px !important;background:rgba(99,102,241,.06) !important}
.previewbar-chip{display:inline-flex;align-items:center;gap:.4rem;align-self:flex-start;max-width:100%;margin-left:.5rem;padding:.32rem .5rem .32rem .72rem;border-radius:999px;background:rgba(255,255,255,.72);border:1px solid rgba(0,0,0,.08);font-size:.78rem;color:#444;backdrop-filter:blur(18px) saturate(1.4);-webkit-backdrop-filter:blur(18px) saturate(1.4);box-shadow:0 6px 20px rgba(0,0,0,.1)}
.previewbar-chip-text{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600;color:#333}
.previewbar-chip-x{border:none;background:rgba(0,0,0,.08);color:#666;border-radius:999px;width:1.15rem;height:1.15rem;font-size:.7rem;cursor:pointer;flex-shrink:0;line-height:1}
.previewbar-chip-x:hover{background:rgba(0,0,0,.14)}
.hello-kanban-result{display:none}
.hello-kanban-result.is-visible{display:grid;grid-template-columns:1fr auto;gap:.28rem .8rem;align-items:center;padding:.9rem 1rem;border-radius:1rem;background:rgba(255,255,255,.94);border:1px solid rgba(11,92,255,.18);box-shadow:0 14px 38px rgba(0,0,0,.14);backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px)}
.hello-kanban-result-kicker{grid-column:1/-1;font-size:.68rem;font-weight:800;letter-spacing:.11em;color:#0b5cff}
.hello-kanban-result-title{font-size:.95rem;color:#17171b;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.hello-kanban-result-status{justify-self:end;padding:.22rem .58rem;border-radius:999px;background:#e7eeff;color:#0040c4;font-size:.74rem;font-weight:800}
.hello-kanban-result-ref{grid-column:1/-1;font-size:.68rem;color:#71717a;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.hello-kanban-result-boundary{font-size:.72rem;color:#71717a}
.hello-kanban-result-link{justify-self:end;color:#0b5cff;font-size:.78rem;font-weight:750;text-decoration:none}
.hello-kanban-result-link:hover{text-decoration:underline}
`

// Pure shadcn page + AI CSS theme. The whole page is ONE shadcn json-render spec;
// `themeCss` is a sanitized plain-CSS theme designed for THIS page (recolors shadcn
// via CSS vars, sizes headings in CSS, restyles [data-slot] elements, adds
// keyframes/etc.). No HTML frame. The theme is scoped to the `.page` wrapper.
function PureThemePage({page, themeCss}) {
  return React.createElement(
    "div",
    {className: "sw-customer-shell page w-full", "data-catalog-valid": String(isValidTree(page))},
    themeCss ? React.createElement("style", {dangerouslySetInnerHTML: {__html: themeCss}}) : null,
    React.createElement(JsonRenderPage, {page})
  )
}

// Inject the sanitized HTML shell as static markup, then mount the json-render
// BODY into its [data-slot] via a SEPARATE React root. The shell is inert (no
// scripts/handlers survive sanitization), so innerHTML is safe; the slot root
// re-renders on page updates without rebuilding the frame.
function HybridPage({shell, shellCss, page}) {
  const hostRef = useRef(null)
  const rootRef = useRef(null)

  useEffect(() => {
    const host = hostRef.current
    if (!host) return
    host.innerHTML = shell
    let slot = host.querySelector("[data-slot]")
    if (!slot) {
      slot = document.createElement("div")
      host.appendChild(slot)
    }
    const root = createRoot(slot)
    rootRef.current = root
    root.render(React.createElement(JsonRenderPage, {page}))
    return () => {
      const r = rootRef.current
      rootRef.current = null
      // defer unmount out of the commit phase to avoid a React warning
      if (r) setTimeout(() => { try { r.unmount() } catch (e) {} }, 0)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [shell])

  useEffect(() => {
    if (rootRef.current) rootRef.current.render(React.createElement(JsonRenderPage, {page}))
  }, [page])

  // The shell's own compiled Tailwind CSS (its AI classes are invisible to the
  // build-time scan) is inlined here; the sanitized shell HTML mounts in hostRef.
  return React.createElement(
    "div",
    {className: "sw-customer-shell w-full", "data-catalog-valid": String(isValidTree(page))},
    shellCss ? React.createElement("style", {dangerouslySetInnerHTML: {__html: shellCss}}) : null,
    React.createElement("div", {ref: hostRef})
  )
}

function ChatPane({messages}) {
  // Customer-visible messages render as left-aligned incoming bubbles. The
  // sw-chat-pane / sw-chat-bubble contract classes are preserved.
  return React.createElement(
    "section",
    {
      className:
        "sw-chat-pane rounded-lg border border-border bg-card px-4 py-3 text-card-foreground shadow-sm",
      "data-pane": "chat",
    },
    messages.length === 0
      ? React.createElement(
          "p",
          {className: "py-6 text-center text-sm italic text-muted-foreground"},
          "No messages yet."
        )
      : messages.map((message) =>
          React.createElement(
            "article",
            {
              className: "sw-chat-bubble flex justify-start",
              "data-message-id": message.id,
              key: message.id,
            },
            React.createElement(
              "p",
              {className: "max-w-[80%] rounded-lg bg-primary px-3 py-2 text-sm text-primary-foreground"},
              message.text || ""
            )
          )
        )
  )
}

function emptyPage() {
  return {type: "container", props: {layout: "stack"}, children: []}
}

const root = document.getElementById("socialware-viewer-root")
if (root) boot(root)
