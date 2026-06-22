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
    <div className="flex min-h-screen bg-background text-foreground">
      <aside className="flex w-60 shrink-0 flex-col gap-4 border-r border-border bg-card p-4" aria-label="World navigation">
        <div className="flex items-center gap-2">
          <div className="flex h-8 w-8 items-center justify-center rounded-md bg-primary font-semibold text-primary-foreground">W</div>
          <div>
            <div className="text-sm font-semibold text-foreground">{title}</div>
            <div className="text-xs text-muted-foreground">ezagent</div>
          </div>
        </div>
        <nav className="flex flex-col gap-0.5">
          <a className="flex items-center gap-2 rounded-md bg-accent px-3 py-1.5 text-sm font-medium text-accent-foreground" href="/">
            <PanelsTopLeft size={16} />
            Overview
          </a>
          <a
            className="flex items-center gap-2 rounded-md px-3 py-1.5 text-sm font-medium text-muted-foreground transition hover:bg-muted hover:text-foreground"
            href="/sessions"
          >
            <PlugZap size={16} />
            Sessions
          </a>
        </nav>
      </aside>

      <main className="min-w-0 flex-1 p-6">
        <section className="flex items-center justify-between gap-4 rounded-lg border border-border bg-card p-6" aria-labelledby="world-title">
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">React/shadcn shell</p>
            <h1 id="world-title" className="mt-1 text-2xl font-semibold text-foreground">
              Hello from World
            </h1>
            <p className="mt-2 max-w-prose text-sm text-muted-foreground">
              A LiveView process owns auth and dispatch. React owns this visible app surface.
            </p>
          </div>
          <Button type="button">Mounted</Button>
        </section>

        <section className="mt-4 grid gap-3 sm:grid-cols-3" aria-label="World runtime context">
          <HelloPanel label="Caller" value={caller?.entity_uri || "anonymous"} />
          <HelloPanel label="Workspace" value={caller?.workspace_uri || "unknown"} />
          <HelloPanel label="Renderer" value="WorldRenderer phx-hook" />
        </section>
      </main>
    </div>
  )
}

function HelloPanel({label, value}: {label: string; value: string}) {
  return (
    <div className="space-y-1 rounded-md border border-border bg-card p-3">
      <span className="block text-xs text-muted-foreground">{label}</span>
      <code className="font-mono text-xs text-foreground">{value}</code>
    </div>
  )
}
