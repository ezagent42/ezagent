import {Socket} from "phoenix"
import React, {useEffect, useMemo, useRef, useState} from "react"
import {createRoot} from "react-dom/client"
import {JsonRenderPage} from "./catalog_jsonrender.mjs"
import {PageShell} from "./theme_shell.mjs"
import {isValidTree} from "./catalog.mjs"

// Print the @json-render page data that actually drives the rendered page to the
// browser DevTools (F12) console — the "useful generated data" an operator wants
// to inspect. Logs the title, a per-type component count, and the full tree.
function logHelloPage(snapshot, source) {
  const page = snapshot && snapshot.page
  if (!page) return
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
  console.log(
    `%c[hello] page ${source} %c${page?.props?.title ?? ""}%c — ${total} nodes`,
    "color:#16a34a;font-weight:bold",
    "color:#2563eb;font-weight:bold",
    "color:inherit",
    {title: page?.props?.title, total, byType: counts, page, messages: snapshot.messages},
  )
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
  const reactRoot = createRoot(root)

  reactRoot.render(
    React.createElement(CustomerApp, {
      sessionUri,
      token,
      socketPath,
      topicPrefix,
    })
  )
}

function CustomerApp({sessionUri, token, socketPath, topicPrefix}) {
  const [snapshot, setSnapshot] = useState(null)
  const [unauthorized, setUnauthorized] = useState(false)

  useEffect(() => {
    const socket = new Socket(socketPath, {params: {session_uri: sessionUri, token}})
    socket.connect()

    const channel = socket.channel(`${topicPrefix}:${sessionUri}`, {})
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
      channel.leave()
      socket.disconnect()
    }
  }, [sessionUri, token, socketPath, topicPrefix])

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
  // A freshly created session has NO generated page yet. Show a clean empty
  // state instead of rendering the theme frame around an empty/placeholder body
  // (which previously surfaced as "Unsupported node: container" — emptyPage()'s
  // node type isn't in the renderer catalog). The frame/page only appears once
  // the builder has actually landed content.
  const childCount = page && Array.isArray(page.children) ? page.children.length : 0
  if (!page || childCount === 0) {
    return React.createElement(
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
  // Hybrid architecture: a HAND-CRAFTED, fixed theme shell (PageShell — nav,
  // aurora background, footer, brand) wraps the AI-authored json-render BODY.
  // The AI only edits the body (json-render data); the beautiful frame is human
  // code and never AI-written → beauty + safety. Brand comes from the page title.
  // (`sw-customer-shell` + `data-catalog-valid` kept — E2E asserts on them.)
  const brand = (page && page.props && page.props.title) || "Hello"
  // Hybrid: prefer the AI-authored, server-sanitised HTML shell (bespoke frame
  // per site). Fall back to the built-in hand-crafted PageShell theme when the
  // session has no shell yet (e.g. pages built before the shell existed).
  if (snapshot.shell) {
    return React.createElement(HybridPage, {
      shell: snapshot.shell,
      shellCss: snapshot.shell_css,
      page,
    })
  }
  return React.createElement(
    "div",
    {
      className: "sw-customer-shell w-full",
      "data-catalog-valid": String(isValidTree(page)),
    },
    React.createElement(PageShell, {brand}, React.createElement(JsonRenderPage, {page}))
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
