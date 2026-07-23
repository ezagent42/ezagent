import type {ReactElement} from "react"

import {Kanban, type KanbanState} from "./Kanban"

export type PluginPageRendererProps = {
  component: {id: string; type: string}
  state: Record<string, unknown>
  onAction: (action: string, args: Record<string, unknown>) => void
}

export function KanbanWorldPage({state, onAction}: PluginPageRendererProps): ReactElement {
  const pageState = state as KanbanState

  return (
    <Kanban
      mode={pageState.kanban_uri ? "operate" : "config"}
      state={pageState}
      onAction={onAction}
    />
  )
}
