import React from "react"
import {TerminalSquare} from "lucide-react"
import {Terminal} from "xterm"
import {FitAddon} from "xterm-addon-fit"
import "xterm/css/xterm.css"

type PtyState = {
  agent_detail_path?: string | null
  agent_status?: {phase?: string; flavor?: string; [key: string]: unknown}
  agent_uri?: string | null
  pty_alive?: boolean
  pty_initial_buffer?: string
  pty_phase?: string
}

type Props = {
  state: PtyState
  onInput: (bytes: string) => void
  onResize: (size: {cols: number; rows: number}) => void
  onServerEvent?: (event: string, callback: (payload: unknown) => void) => void
}

export function PtyTerminalSurface({state, onInput, onResize, onServerEvent}: Props) {
  const containerRef = React.useRef<HTMLDivElement | null>(null)
  const termRef = React.useRef<Terminal | null>(null)

  React.useEffect(() => {
    if (!state.agent_uri || !state.pty_alive || !containerRef.current) return undefined

    const term = new Terminal({
      fontFamily: '"SF Mono", Menlo, Consolas, "DejaVu Sans Mono", monospace',
      fontSize: 13,
      theme: {background: "#111827", foreground: "#d1d5db"},
      cursorBlink: true,
    })
    const fitAddon = new FitAddon()

    term.loadAddon(fitAddon)
    term.open(containerRef.current)
    fitAddon.fit()
    onResize({cols: term.cols, rows: term.rows})
    term.onData((data) => onInput(data))

    const resize = () => {
      fitAddon.fit()
      onResize({cols: term.cols, rows: term.rows})
    }

    window.addEventListener("resize", resize)
    if (state.pty_initial_buffer) term.write(state.pty_initial_buffer)
    termRef.current = term

    return () => {
      window.removeEventListener("resize", resize)
      term.dispose()
      termRef.current = null
    }
  }, [state.agent_uri, state.pty_alive])

  React.useEffect(() => {
    if (!onServerEvent) return undefined

    onServerEvent("pty_chunk", (payload) => {
      const chunk = payload as {bytes?: string}
      if (chunk.bytes) termRef.current?.write(chunk.bytes)
    })

    return undefined
  }, [onServerEvent])

  const phase = state.agent_status?.phase || "unknown"
  const ptyPhase = state.pty_phase || "unknown"

  return (
    <section className="space-y-4 rounded-lg border border-border bg-card p-5 text-card-foreground" data-world-component="pty_terminal">
      <div className="flex items-center justify-between gap-3">
        <div>
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Terminal</p>
          <h2 className="text-lg font-semibold text-foreground">PTY terminal</h2>
        </div>
        <TerminalSquare aria-hidden="true" className="h-4 w-4 text-muted-foreground" />
      </div>

      <div className="flex flex-wrap items-center gap-3 text-xs text-muted-foreground">
        {state.agent_detail_path ? (
          <a className="text-primary hover:underline" href={state.agent_detail_path}>
            Agent
          </a>
        ) : (
          <span>Agent</span>
        )}
        <code className="font-mono text-foreground">{state.agent_uri || "invalid agent"}</code>
        <span data-phase={phase}>Kind {phase}</span>
        <span data-pty-phase={ptyPhase}>PTY {ptyPhase}</span>
      </div>

      {state.agent_uri && state.pty_alive ? (
        <div ref={containerRef} className="h-[420px] w-full overflow-hidden rounded-md border border-border bg-[#111827] p-2" />
      ) : (
        <div className="space-y-1 rounded-md border border-dashed border-border bg-muted/40 p-6 text-center">
          <strong className="text-foreground">Terminal not available</strong>
          <p className="text-sm text-muted-foreground">{terminalHelp(state.agent_status?.flavor)}</p>
        </div>
      )}
    </section>
  )
}

function terminalHelp(flavor: unknown) {
  if (flavor === "cc") return "The PTY process for this cc agent is not running yet."
  if (flavor === "py" || flavor === "curl") return `This flavor (${flavor}) does not run under a PTY.`

  return "This agent is not backed by a PTY server."
}
