import React from "react"
import {TerminalSquare} from "lucide-react"

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

declare global {
  interface Window {
    Terminal?: new (options: Record<string, unknown>) => XtermTerminal
    FitAddon?: {FitAddon: new () => XtermFitAddon}
  }
}

type XtermTerminal = {
  cols: number
  rows: number
  dispose: () => void
  loadAddon: (addon: XtermFitAddon) => void
  onData: (callback: (data: string) => void) => void
  open: (element: HTMLElement) => void
  write: (bytes: string) => void
}

type XtermFitAddon = {
  fit: () => void
}

export function PtyTerminalSurface({state, onInput, onResize, onServerEvent}: Props) {
  const containerRef = React.useRef<HTMLDivElement | null>(null)
  const termRef = React.useRef<XtermTerminal | null>(null)
  const [clientError, setClientError] = React.useState<string | null>(null)

  React.useEffect(() => {
    if (!state.agent_uri || !state.pty_alive || !containerRef.current) return undefined

    if (!window.Terminal || !window.FitAddon?.FitAddon) {
      setClientError("xterm runtime is not loaded.")
      return undefined
    }

    const term = new window.Terminal({
      fontFamily: '"SF Mono", Menlo, Consolas, "DejaVu Sans Mono", monospace',
      fontSize: 13,
      theme: {background: "#111827", foreground: "#d1d5db"},
      cursorBlink: true,
    })
    const fitAddon = new window.FitAddon.FitAddon()

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
    <section className="world-section world-pty-terminal" data-world-component="pty_terminal">
      <div className="world-section-header">
        <div>
          <p className="world-eyebrow">Terminal</p>
          <h2>PTY terminal</h2>
        </div>
        <TerminalSquare aria-hidden="true" />
      </div>

      <div className="world-terminal-toolbar">
        {state.agent_detail_path ? <a href={state.agent_detail_path}>Agent</a> : <span>Agent</span>}
        <code>{state.agent_uri || "invalid agent"}</code>
        <span data-phase={phase}>Kind {phase}</span>
        <span data-pty-phase={ptyPhase}>PTY {ptyPhase}</span>
      </div>

      {clientError && <p className="world-error">{clientError}</p>}

      {state.agent_uri && state.pty_alive ? (
        <div ref={containerRef} className="world-terminal-mount" />
      ) : (
        <div className="world-terminal-empty">
          <strong>Terminal not available</strong>
          <p>{terminalHelp(state.agent_status?.flavor)}</p>
        </div>
      )}
    </section>
  )
}

function terminalHelp(flavor: unknown) {
  if (flavor === "cc") return "The PTY process for this cc agent is not running yet."
  if (flavor === "echo" || flavor === "curl") return `This flavor (${flavor}) does not run under a PTY.`

  return "This agent is not backed by a PTY server."
}
