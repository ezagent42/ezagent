// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/ezagent_web"
import topbar from "../vendor/topbar"
import {MentionAutocomplete} from "./hooks/mention_autocomplete"
import {CountUp} from "./hooks/count_up"
import {PtyTerminal} from "./hooks/pty_terminal"
import {UriPicker} from "./hooks/uri_picker"
import {ViewportMarkRead} from "./hooks/viewport_mark_read"
import {WorldRenderer} from "../../../ezagent_plugin_world/assets/js/world_renderer"
import {HelloRenderer} from "../../../ezagent_plugin_hello/assets/js/hello_renderer"

// Auto-scroll messages stream on new inserts AND preserve visual
// position on history prepend.
//
// Two cases this hook handles:
//   1. New chat message arrives (append at bottom) — scroll to bottom
//      iff the operator was already near it (don't yank from history).
//   2. Operator clicks "↑ Load older" (PR-5 prepend at top) — keep the
//      previously-topmost visible message at the same visual position
//      so the operator's eye doesn't jump. Without this, they'd either
//      stay glued to the bottom (case 1's rule) and never see the new
//      older messages, or jump to msg-1 and lose their place.
//
// Detection: beforeUpdate captures scrollHeight; updated compares.
// If height grew more than the bottom-room allowed, that growth came
// from a prepend — adjust scrollTop by the delta to compensate.
const ScrollOnUpdate = {
  _firstChildId() { return this.el.firstElementChild ? this.el.firstElementChild.id : null },
  mounted() {
    this.el.scrollTop = this.el.scrollHeight
    this._prevHeight = this.el.scrollHeight
    this._prevFirstId = this._firstChildId()
  },
  beforeUpdate() {
    this._prevHeight = this.el.scrollHeight
    this._prevScrollTop = this.el.scrollTop
    this._prevFirstId = this._firstChildId()
  },
  updated() {
    const el = this.el
    const grew = el.scrollHeight - (this._prevHeight || 0)
    const firstChanged = this._firstChildId() !== this._prevFirstId

    if (grew > 0 && firstChanged) {
      // Prepend (e.g. "↑ Load older"). Scroll up to reveal the newly
      // added older messages while keeping previously-visible content
      // still on screen as the user's anchor.
      el.scrollTop = grew
    } else {
      // Append (new chat message). Follow it down iff already near bottom.
      const wasNearBottom =
        (this._prevHeight || 0) - (this._prevScrollTop || 0) - el.clientHeight < 120
      if (wasNearBottom) el.scrollTop = el.scrollHeight
    }
    this._prevHeight = el.scrollHeight
    this._prevFirstId = this._firstChildId()
  }
}

// Domain.Pty PR-C (2026-05-21): the xterm.js PtyTerminal hook moved
// to apps/ezagent_web/assets/js/hooks/pty_terminal.js. Import is at
// the top of this file alongside the other hooks.

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ScrollOnUpdate, PtyTerminal, MentionAutocomplete, CountUp, UriPicker, ViewportMarkRead, WorldRenderer, HelloRenderer},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// V1 UI PR-2 (SPEC §2.4) — CmdK command palette open-trigger.
//
// The open behavior is app-GLOBAL, not bound to one component
// instance, so it is plain global JS here — NOT a phx-hook (a hook
// needs a mount-point element). Two paths both end at one place:
//
//   1. The header search button dispatches `ezagent:open-command-palette`
//      (see ide_shell.ex top_command_bar).
//   2. ⌘K / Ctrl+K dispatches the same custom event.
//
// The CommandPaletteComponent (#cmdk) renders a `data-cmdk-open`
// attribute holding a serialized `JS.push("cmdk_open", target: @myself)`.
// The listener reads that attribute and execJS-es it, routing the
// canonical `cmdk_open` event (SPEC §2.5) to that LiveComponent. If
// the palette isn't on the page (no `#cmdk`), this is a harmless no-op.
window.addEventListener("ezagent:open-command-palette", () => {
  const palette = document.getElementById("cmdk")
  if (palette) {
    const cmd = palette.getAttribute("data-cmdk-open")
    if (cmd) liveSocket.execJS(palette, cmd)
  }
})
window.addEventListener("keydown", (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === "k") {
    e.preventDefault()
    window.dispatchEvent(new CustomEvent("ezagent:open-command-palette"))
  }
})

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", () => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
