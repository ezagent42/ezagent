import {Socket} from "phoenix"
import React, {useEffect, useMemo, useState} from "react"
import {createRoot} from "react-dom/client"
import {Sandpack} from "@codesandbox/sandpack-react"
import {createBaseRegistry, renderJsonNode} from "./json_render.mjs"

function boot(root) {
  const sessionUri = root.dataset.sessionUri
  const token = root.dataset.token
  const reactRoot = createRoot(root)

  reactRoot.render(
    React.createElement(CustomerApp, {
      sessionUri,
      token,
    })
  )
}

function CustomerApp({sessionUri, token}) {
  const [snapshot, setSnapshot] = useState(null)
  const [unauthorized, setUnauthorized] = useState(false)
  const registry = useMemo(() => createBaseRegistry(React, Sandpack), [])

  useEffect(() => {
    const socket = new Socket("/socialware_socket", {params: {session_uri: sessionUri, token}})
    socket.connect()

    const channel = socket.channel(`socialware:customer:${sessionUri}`, {})
    channel
      .join()
      .receive("ok", ({snapshot}) => setSnapshot(snapshot))
      .receive("error", () => setUnauthorized(true))

    channel.on("snapshot", (snapshot) => setSnapshot(snapshot))

    return () => {
      channel.leave()
      socket.disconnect()
    }
  }, [sessionUri, token])

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
  return React.createElement(
    "div",
    {className: "sw-customer-shell mx-auto flex w-full max-w-2xl flex-col gap-6"},
    React.createElement(
      "header",
      {className: "flex flex-col gap-1"},
      React.createElement(
        "h1",
        {className: "text-xl font-semibold tracking-tight text-base-content"},
        "Your conversation"
      ),
      React.createElement(
        "p",
        {className: "text-sm text-base-content/60"},
        "Live updates appear here automatically."
      )
    ),
    React.createElement(ChatPane, {messages: snapshot.messages || []}),
    renderJsonNode(React, snapshot.page || emptyPage(), registry)
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
