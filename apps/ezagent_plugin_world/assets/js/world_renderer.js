export const WorldRenderer = {
  async mounted() {
    this._worldUnmount = null
    const moduleUrl = this.el.dataset.worldModuleUrl

    if (!moduleUrl) {
      console.error("WorldRenderer missing data-world-module-url")
      return
    }

    try {
      ensureStylesheet(this.el.dataset.worldCssUrl)
      await ensureViteReactPreamble(moduleUrl)
      const mod = await import(/* @vite-ignore */ moduleUrl)
      this._worldUnmount = mod.mountWorld(this.el, {
        layout: parseJson(this.el.dataset.layout, {}),
        caller: parseJson(this.el.dataset.caller, {}),
        pushEvent: (event, payload, onReply) => {
          this.pushEventTo(this.el, event, payload, onReply)
        },
        onServerEvent: (event, callback) => this.handleEvent(event, callback),
      })
    } catch (error) {
      console.error("WorldRenderer failed to mount", error)
      this.el.dataset.worldMountError = "true"
    }
  },

  destroyed() {
    if (this._worldUnmount) this._worldUnmount()
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
