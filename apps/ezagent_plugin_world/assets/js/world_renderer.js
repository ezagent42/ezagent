import {worldNavigationTarget} from "./world_navigation.js"

export const WorldRenderer = {
  async mounted() {
    this._world = null
    this._lastCallerJson = this.el.dataset.caller || ""
    this._lastDispatchStatus = null
    this._worldNavigate = (event) => {
      const to = worldNavigationTarget(event, this.el)
      if (!to) return

      event.preventDefault()
      this.pushEventTo(this.el, "world:navigate", {to})
    }

    this.el.addEventListener("click", this._worldNavigate)
    const moduleUrl = this.el.dataset.worldModuleUrl

    if (!moduleUrl) {
      console.error("WorldRenderer missing data-world-module-url")
      return
    }

    try {
      ensureStylesheet(this.el.dataset.worldCssUrl)
      await ensureViteReactPreamble(moduleUrl)
      const mod = await import(/* @vite-ignore */ moduleUrl)
      this._world = mod.mountWorld(this.el, {
        layout: parseJson(this.el.dataset.layout, {}),
        state: parseJson(this.el.dataset.worldState, {}),
        pluginNav: parseJson(this.el.dataset.pluginNav, []),
        caller: parseJson(this.el.dataset.caller, {}),
        pushEvent: (event, payload, onReply) => {
          this.pushEventTo(this.el, event, payload, onReply)
        },
        onServerEvent: (event, callback) => this.handleEvent(event, callback),
      })
      this._lastDispatchStatus = this.el.dataset.lastDispatch || null
    } catch (error) {
      console.error("WorldRenderer failed to mount", error)
      this.el.dataset.worldMountError = "true"
    }
  },

  updated() {
    // data 属性会穿过 phx-update="ignore" 被 patch（同 uri_picker.js 的先例），
    // 但 React 岛不会自动重读。把最新的 caller 和 data-last-dispatch 推进岛里。
    const callerJson = this.el.dataset.caller || ""

    if (callerJson !== this._lastCallerJson) {
      this._lastCallerJson = callerJson
      this._world?.setCaller(parseJson(callerJson, {}))
    }

    const status = this.el.dataset.lastDispatch || null
    if (status === this._lastDispatchStatus) return

    this._lastDispatchStatus = status
    this._world?.setDispatchStatus(status)
  },

  destroyed() {
    if (this._worldNavigate) this.el.removeEventListener("click", this._worldNavigate)
    if (this._world) this._world.unmount()
  },
}

async function ensureViteReactPreamble(moduleUrl) {
  const url = new URL(moduleUrl, window.location.href)

  if (!url.pathname.startsWith("/src/") || window.__vite_plugin_react_preamble_installed__) {
    return
  }

  const RefreshRuntime = await import(/* @vite-ignore */ `${url.origin}/@react-refresh`)
  RefreshRuntime.default.injectIntoGlobalHook(window)
  window.$RefreshReg$ = () => {}
  window.$RefreshSig$ = () => (type) => type
  window.__vite_plugin_react_preamble_installed__ = true
}

function ensureStylesheet(cssUrl) {
  if (!cssUrl || document.querySelector(`link[data-world-css-url="${cssUrl}"]`)) return

  const link = document.createElement("link")
  link.rel = "stylesheet"
  link.href = cssUrl
  link.dataset.worldCssUrl = cssUrl
  document.head.appendChild(link)
}

function parseJson(value, fallback) {
  if (!value) return fallback

  try {
    return JSON.parse(value)
  } catch (_error) {
    return fallback
  }
}
