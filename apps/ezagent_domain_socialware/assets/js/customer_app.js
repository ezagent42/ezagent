import {Socket} from "phoenix"
import React, {useEffect, useMemo, useRef, useState} from "react"
import {createRoot} from "react-dom/client"
import {JsonRenderPage} from "./catalog_jsonrender.mjs"
import {PageShell} from "./theme_shell.mjs"
import {isValidTree} from "./catalog.mjs"

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
// browser DevTools (F12) console — the "useful generated data" an operator wants
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
      `%c✏️ [hello] ${changes.length} change(s)`,
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

function boot(root) {
  const sessionUri = root.dataset.sessionUri
  const token = root.dataset.token
  // The socket PATH and channel topic PREFIX are read from the mount element so
  // the SAME SPA serves both the customer feed and the chat feed (P4 codex
  // finding 3). Both default to the customer values, so an existing
  // customer-feed page (which sets neither attribute) is byte-identical to
  // before.
  const socketPath = root.dataset.socketPath || "/socialware_socket"
  const topicPrefix = root.dataset.topicPrefix || "socialware:customer"
  // Identity token for the logged-in viewer (or "" anonymous). Drives the bar's
  // login/join/post states; the channel re-derives logged_in/member from it.
  const viewerToken = root.dataset.viewerToken || ""
  const reactRoot = createRoot(root)

  reactRoot.render(
    React.createElement(CustomerApp, {
      sessionUri,
      token,
      socketPath,
      topicPrefix,
      viewerToken,
    })
  )
}

function CustomerApp({sessionUri, token, socketPath, topicPrefix, viewerToken}) {
  const [snapshot, setSnapshot] = useState(null)
  const [unauthorized, setUnauthorized] = useState(false)
  // Debug: highlight which parts of the page are json-render (vs the HTML frame).
  const [jrHighlight, setJrHighlight] = useState(false)
  // The bottom preview bar: whether the chat history panel is expanded, and a
  // ref to the live channel so the bar's join/post actions can push to it.
  const [chatOpen, setChatOpen] = useState(false)
  const channelRef = useRef(null)
  useEffect(() => {
    document.body.classList.toggle("jr-highlight", jrHighlight)
    return () => document.body.classList.remove("jr-highlight")
  }, [jrHighlight])

  useEffect(() => {
    const socket = new Socket(socketPath, {params: {session_uri: sessionUri, token, viewer_token: viewerToken}})
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
  }, [sessionUri, token, socketPath, topicPrefix, viewerToken])

  if (unauthorized) {
    return React.createElement(
      "div",
      {
        className: "mx-auto max-w-md py-16 text-center",
        "data-state": "unauthorized",
      },
      React.createElement(
        "div",
        {className: "alert alert-error justify-center"},
        React.createElement("span", {className: "font-medium"}, "Unauthorized")
      )
    )
  }

  if (!snapshot) {
    return React.createElement(
      "div",
      {
        className: "flex flex-col items-center gap-3 py-24 text-base-content/60",
        "data-state": "loading",
      },
      React.createElement("span", {className: "loading loading-dots loading-lg"}),
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
        className: "sw-customer-shell flex min-h-[60vh] w-full flex-col items-center justify-center gap-3 px-6 text-center text-base-content/50",
        "data-catalog-valid": "true",
        "data-empty": "true",
      },
      React.createElement("div", {className: "text-4xl"}, "🪄"),
      React.createElement("p", {className: "text-base font-medium text-base-content/70"}, "还没有页面"),
      React.createElement("p", {className: "max-w-sm text-sm"}, "在聊天里 @hello 描述你想要的页面,生成的页面会显示在这里。")
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
    ch.push("post", {text})
      .receive("error", (e) => console.warn("[hello] post failed:", e))
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
    React.createElement(PreviewBar, {
      viewer,
      messages,
      chatOpen,
      setChatOpen,
      onJoin: doJoin,
      onPost: doPost,
      onLogin: doLogin,
    }),
    React.createElement(
      "button",
      {
        type: "button",
        onClick: () => setJrHighlight((v) => !v),
        className:
          "fixed bottom-4 right-4 z-[9999] rounded-full px-4 py-2 text-sm font-semibold shadow-lg transition " +
          (jrHighlight ? "bg-fuchsia-600 text-white" : "bg-base-100 text-base-content/70 ring-1 ring-base-300 hover:ring-fuchsia-400"),
        title: "高亮页面里属于 json-render 的部分(框架是 HTML,不高亮)",
      },
      jrHighlight ? "✕ 隐藏 json-render" : "◐ 高亮 json-render"
    )
  )
}

// Highlight overlay: every json-render node carries `data-jr-type`; the HTML frame
// (nav/footer/background) has none, so toggling this clearly separates the two.
const JR_HIGHLIGHT_CSS = `
body.jr-highlight [data-slot]{outline:2px solid #d946ef;outline-offset:-2px}
body.jr-highlight [data-jr-type]{outline:1px dashed rgba(217,70,239,.55);outline-offset:-1px;position:relative}
body.jr-highlight [data-jr-type]::before{content:attr(data-jr-type);position:absolute;top:0;left:0;background:#d946ef;color:#fff;font:600 10px/1 ui-monospace,monospace;padding:2px 4px;border-radius:0 0 4px 0;z-index:9999;pointer-events:none}
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
function PreviewBar({viewer, messages, chatOpen, setChatOpen, onJoin, onPost, onLogin}) {
  const [draft, setDraft] = useState("")
  const loggedIn = !!(viewer && viewer.logged_in)
  const member = loggedIn && !!viewer.member
  const submit = () => {
    const t = draft.trim()
    if (!t || !member) return
    onPost(t)
    setDraft("")
  }

  let action
  if (!loggedIn) {
    action = React.createElement("button", {type: "button", className: "previewbar-action", onClick: onLogin}, "登录")
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
    ? "登录后参与对话"
    : !member
      ? "加入会话后即可发言"
      : "说点什么 —— 直接发给页面作者,无需 @hello"

  return React.createElement(
    "div",
    {className: "previewbar-wrap", "data-viewer": member ? "member" : loggedIn ? "guest" : "anon"},
    chatOpen ? React.createElement(ChatPanel, {messages, onClose: () => setChatOpen(false)}) : null,
    React.createElement(
      "div",
      {className: "previewbar"},
      React.createElement(
        "button",
        {type: "button", className: "previewbar-toggle", onClick: () => setChatOpen((v) => !v), title: "查看会话", "aria-label": "查看会话"},
        chatOpen ? "▾" : "▴"
      ),
      React.createElement("input", {
        className: "previewbar-input",
        value: draft,
        disabled: !member,
        placeholder,
        onChange: (e) => setDraft(e.target.value),
        onKeyDown: (e) => {
          if (e.key === "Enter" && !e.nativeEvent.isComposing) {
            e.preventDefault()
            submit()
          }
        },
      }),
      action
    )
  )
}

function ChatPanel({messages, onClose}) {
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
      {className: "previewbar-chat-body"},
      messages.length === 0
        ? React.createElement("p", {className: "previewbar-chat-empty"}, "还没有消息。")
        : messages.map((m, i) =>
            React.createElement(
              "div",
              {key: m.id || i, className: "previewbar-msg"},
              m.sender ? React.createElement("span", {className: "previewbar-msg-who"}, shortSender(m.sender)) : null,
              React.createElement("span", {className: "previewbar-msg-text"}, m.text || "")
            )
          )
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
.previewbar-toggle{flex-shrink:0;width:2.1rem;height:2.1rem;border-radius:999px;border:none;background:rgba(0,0,0,.05);color:#444;cursor:pointer;font-size:.85rem;line-height:1;transition:background .15s}
.previewbar-toggle:hover{background:rgba(0,0,0,.1)}
.previewbar-input{flex:1;min-width:0;border:none;background:transparent;outline:none;font-size:.95rem;color:#181818;height:2.4rem;padding:0 .25rem}
.previewbar-input:disabled{color:#8a8a8a;cursor:not-allowed}
.previewbar-input::placeholder{color:#9a9a9a}
.previewbar-action{flex-shrink:0;height:2.4rem;padding:0 1.25rem;border-radius:999px;border:none;background:#1c1c1c;color:#fff;font-weight:600;font-size:.88rem;cursor:pointer;transition:opacity .15s,transform .1s}
.previewbar-action:hover{opacity:.9}
.previewbar-action:active{transform:scale(.97)}
.previewbar-action:disabled{opacity:.38;cursor:default}
.previewbar-chat{max-height:50vh;display:flex;flex-direction:column;border-radius:1.4rem;background:rgba(255,255,255,.86);backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);border:1px solid rgba(0,0,0,.06);box-shadow:0 16px 44px rgba(0,0,0,.16);overflow:hidden;animation:previewbar-rise .18s ease}
@keyframes previewbar-rise{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}
.previewbar-chat-head{display:flex;align-items:center;justify-content:space-between;padding:.65rem .95rem;border-bottom:1px solid rgba(0,0,0,.06);font-weight:600;font-size:.85rem;color:#444;flex-shrink:0}
.previewbar-chat-close{border:none;background:transparent;cursor:pointer;color:#999;font-size:.85rem;line-height:1}
.previewbar-chat-body{overflow-y:auto;padding:.8rem .95rem;display:flex;flex-direction:column;gap:.7rem}
.previewbar-chat-empty{color:#9a9a9a;font-size:.85rem;text-align:center;padding:1.2rem 0;margin:0}
.previewbar-msg{display:flex;flex-direction:column;gap:.12rem}
.previewbar-msg-who{font-size:.68rem;font-weight:700;color:#6d5cf0;text-transform:uppercase;letter-spacing:.03em}
.previewbar-msg-text{font-size:.9rem;line-height:1.5;color:#222;white-space:pre-wrap;word-break:break-word}
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
  // daisyUI chat bubbles. Customer-visible messages render as left-aligned
  // (`chat-start`) incoming bubbles. The sw-chat-pane / sw-chat-bubble
  // contract classes are preserved (E2E + data-message-id markers kept).
  return React.createElement(
    "section",
    {
      className:
        "sw-chat-pane card border border-base-300 bg-base-100 px-4 py-3 shadow-sm",
      "data-pane": "chat",
    },
    messages.length === 0
      ? React.createElement(
          "p",
          {className: "py-6 text-center text-sm italic text-base-content/50"},
          "No messages yet."
        )
      : messages.map((message) =>
          React.createElement(
            "article",
            {
              className: "sw-chat-bubble chat chat-start",
              "data-message-id": message.id,
              key: message.id,
            },
            React.createElement(
              "p",
              {className: "chat-bubble chat-bubble-primary text-sm"},
              message.text || ""
            )
          )
        )
  )
}

function emptyPage() {
  return {type: "container", props: {layout: "stack"}, children: []}
}

const root = document.getElementById("socialware-customer-root")
if (root) boot(root)
