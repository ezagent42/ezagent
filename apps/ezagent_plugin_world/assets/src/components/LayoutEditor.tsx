import {ArrowDown, ArrowUp, RotateCcw} from "lucide-react"

import {Button} from "./ui/primitives"

type LayoutComponent = {
  id: string
  type: string
  placement?: {x?: number; y?: number; w?: number; h?: number}
  props?: Record<string, unknown>
}

type WorldLayout = {
  version?: number
  scope?: string
  components?: LayoutComponent[]
}

type LayoutEditorProps = {
  canManage?: boolean
  layout: WorldLayout
  onManageLayout?: (layout: WorldLayout) => void
}

export function LayoutEditor({canManage = false, layout, onManageLayout}: LayoutEditorProps) {
  const components = [...(layout.components || [])].sort((a, b) => (a.placement?.y || 0) - (b.placement?.y || 0))

  return (
    <section className="world-section world-layout-editor" aria-labelledby="layout-editor-title" data-world-component="layout_editor">
      <div className="world-section-header">
        <div>
          <h2 id="layout-editor-title">Layout</h2>
          <p>{canManage ? "Arrange the world screen." : "Layout changes require manage access."}</p>
        </div>
        <Button size="sm" variant="secondary" disabled={!canManage} onClick={() => onManageLayout?.(reflow(layout, components))}>
          <RotateCcw aria-hidden="true" />
          Reset
        </Button>
      </div>

      <div className="world-layout-list">
        {components.map((component, index) => (
          <div className="world-layout-row" key={component.id}>
            <div>
              <span className="world-layout-type">{component.type}</span>
              <span className="world-layout-id">{component.id}</span>
            </div>
            <div className="world-layout-actions">
              <Button
                size="icon"
                variant="secondary"
                disabled={!canManage || index === 0}
                aria-label={`Move ${component.type} up`}
                onClick={() => onManageLayout?.(move(layout, index, -1))}
              >
                <ArrowUp aria-hidden="true" />
              </Button>
              <Button
                size="icon"
                variant="secondary"
                disabled={!canManage || index === components.length - 1}
                aria-label={`Move ${component.type} down`}
                onClick={() => onManageLayout?.(move(layout, index, 1))}
              >
                <ArrowDown aria-hidden="true" />
              </Button>
            </div>
          </div>
        ))}
      </div>
    </section>
  )
}

function move(layout: WorldLayout, from: number, delta: -1 | 1) {
  const components = [...(layout.components || [])].sort((a, b) => (a.placement?.y || 0) - (b.placement?.y || 0))
  const to = from + delta

  if (to < 0 || to >= components.length) return layout

  const next = [...components]
  const [item] = next.splice(from, 1)
  next.splice(to, 0, item)

  return reflow(layout, next)
}

function reflow(layout: WorldLayout, components: LayoutComponent[]) {
  return {
    version: layout.version || 1,
    scope: layout.scope,
    components: components.map((component, index) => ({
      ...component,
      placement: {
        x: component.placement?.x || 0,
        y: index * 2,
        w: component.placement?.w || 12,
        h: component.placement?.h || 2,
      },
    })),
  }
}
