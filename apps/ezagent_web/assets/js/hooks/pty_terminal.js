import {Terminal} from "xterm"
import {FitAddon} from "xterm-addon-fit"

// PTY terminal — xterm.js LiveView hook.
//
// Mounts an xterm.js Terminal inside `this.el`, subscribes to PubSub
// output via `handleEvent("pty_chunk", ...)`, and routes every
// keystroke through `pushEvent("pty_input", {bytes})` — which the LV
// then dispatches via Ezagent.Invocation.dispatch (CapBAC + audit + ...).
//
// Moved from `apps/ezagent_web/assets/js/app.js` to its own hook file
// per Domain.Pty SPEC §3.2 PR-C (2026-05-21). The xterm.js hook stays
// in `apps/ezagent_web/assets/js/hooks/` because LV hooks are a
// browser-layer concern regardless of which Elixir module mounts them.
//
// CRITICAL: xterm input MUST go through pushEvent → LV → Invocation.dispatch.
// Never write to a PubSub topic directly from the JS side. The
// agents_pty_input_dispatch_test asserts the audit row count matches
// the input byte count — any future regression that bypasses dispatch
// will fail that test.
export const PtyTerminal = {
  mounted() {
    const term = new Terminal({
      fontFamily: '"SF Mono", Menlo, Consolas, "DejaVu Sans Mono", monospace',
      fontSize: 13,
      theme: {background: "#1e1e1e", foreground: "#d4d4d4"},
      cursorBlink: true
    })
    const fitAddon = new FitAddon()
    term.loadAddon(fitAddon)
    term.open(this.el)
    fitAddon.fit()

    // Send window size to backend so PtyServer can :exec.winsz/3.
    this.pushEvent("pty_resize", {cols: term.cols, rows: term.rows})

    // Keystrokes → LV. NEVER PubSub directly (invariant #1).
    term.onData((data) => {
      this.pushEvent("pty_input", {bytes: data})
    })

    // Resize events also go to LV (which dispatches via Invocation).
    window.addEventListener("resize", () => {
      fitAddon.fit()
      this.pushEvent("pty_resize", {cols: term.cols, rows: term.rows})
    })

    // PubSub output chunks arrive via LV → pushEvent.
    this.handleEvent("pty_chunk", ({bytes}) => term.write(bytes))

    this.term = term
  },
  destroyed() {
    if (this.term) this.term.dispose()
  }
}
