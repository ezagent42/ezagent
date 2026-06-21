import {PanelsTopLeft, PlugZap} from "lucide-react"

import {Button} from "./ui/primitives"

type WorldHelloProps = {
  title?: string
  caller?: {
    entity_uri?: string | null
    workspace_uri?: string | null
  }
}

export function WorldHello({title = "World", caller}: WorldHelloProps) {
  return (
    <div className="world-page">
      <aside className="world-sidebar" aria-label="World navigation">
        <div className="world-brand">
          <div className="world-brand-mark">W</div>
          <div>
            <div className="world-brand-title">{title}</div>
            <div className="world-brand-subtitle">ezagent</div>
          </div>
        </div>
        <nav className="world-nav">
          <a className="world-nav-item world-nav-item-active" href="/">
            <PanelsTopLeft size={16} />
            Overview
          </a>
          <a className="world-nav-item" href="/sessions">
            <PlugZap size={16} />
            Sessions
          </a>
        </nav>
      </aside>

      <main className="world-main">
        <section className="world-hero" aria-labelledby="world-title">
          <div>
            <p className="world-kicker">React/shadcn shell</p>
            <h1 id="world-title">Hello from World</h1>
            <p className="world-copy">
              A LiveView process owns auth and dispatch. React owns this visible app surface.
            </p>
          </div>
          <Button type="button">Mounted</Button>
        </section>

        <section className="world-grid" aria-label="World runtime context">
          <div className="world-panel">
            <span className="world-panel-label">Caller</span>
            <code>{caller?.entity_uri || "anonymous"}</code>
          </div>
          <div className="world-panel">
            <span className="world-panel-label">Workspace</span>
            <code>{caller?.workspace_uri || "unknown"}</code>
          </div>
          <div className="world-panel">
            <span className="world-panel-label">Renderer</span>
            <code>WorldRenderer phx-hook</code>
          </div>
        </section>
      </main>
    </div>
  )
}
