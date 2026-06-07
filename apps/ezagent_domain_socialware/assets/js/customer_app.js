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
    return React.createElement("p", {"data-state": "unauthorized"}, "Unauthorized")
  }

  if (!snapshot) {
    return React.createElement("p", {"data-state": "loading"}, "Loading")
  }

  return React.createElement(
    "div",
    {className: "sw-customer-shell"},
    React.createElement(ChatPane, {messages: snapshot.messages || []}),
    renderJsonNode(React, snapshot.page || emptyPage(), registry)
  )
}

function ChatPane({messages}) {
  return React.createElement(
    "section",
    {className: "sw-chat-pane", "data-pane": "chat"},
    messages.map((message) =>
      React.createElement(
        "article",
        {className: "sw-chat-bubble", "data-message-id": message.id, key: message.id},
        React.createElement("p", {}, message.text || "")
      )
    )
  )
}

function emptyPage() {
  return {type: "container", props: {layout: "stack"}, children: []}
}

const root = document.getElementById("socialware-customer-root")
if (root) boot(root)
