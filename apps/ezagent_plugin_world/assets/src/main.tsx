import React from "react"
import {createRoot, type Root} from "react-dom/client"

import {SessionsTable} from "./components/SessionsTable"
import {WorldHello} from "./components/WorldHello"
import "./styles.css"

type WorldLayout = {
  components?: Array<{
    id: string
    type: string
    props?: Record<string, unknown>
  }>
}

type WorldMountOptions = {
  layout?: WorldLayout
  state?: WorldState
  caller?: {
    entity_uri?: string | null
    workspace_uri?: string | null
  }
  pushEvent?: (event: string, payload: unknown, onReply?: (reply: unknown) => void) => void
  onServerEvent?: (event: string, callback: (payload: unknown) => void) => void
}

type WorldState = {
  component?: string
  current_session_uri?: string | null
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
  const [state, setState] = React.useState<WorldState>(() => initialState || {})

  React.useEffect(() => {
    if (!onServerEvent) return undefined

    onServerEvent("world:state", (payload) => {
      setState((current) => ({...current, ...(payload as WorldState)}))
    })

    return undefined
  }, [onServerEvent])

  const component = layout?.components?.[0]
  const props = (component?.props || {}) as {title?: string}

  if (component?.type === "sessions_table" || state.component === "sessions_table") {
    return (
      <SessionsTable
        state={state}
        onJoin={(sessionUri) => {
          pushEvent?.("world:dispatch", {
            action: "sessions.join",
            args: {session_uri: sessionUri},
          })
        }}
      />
    )
  }

  return <WorldHello title={props.title} caller={caller} />
}
