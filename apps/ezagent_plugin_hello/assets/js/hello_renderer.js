// LiveView phx-hook that hydrates hello's @json-render island inside the world
// internal shell. Registered in ezagent_web's app.js LiveSocket hooks (NOT in
// world). It dynamically imports the built island bundle
// (`data-hello-module-url` → `/assets/hello/main.js`) and calls
// `mountHello(el, {spec})` with the session's approved Surface tree
// (`data-spec`). Mirrors world_renderer.js, minus the Vite dev preamble — hello
// ships a pre-built bundle, so no `/@react-refresh` dance.
export const HelloRenderer = {
  async mounted() {
    this._unmount = null
    await this._render()
  },

  // The page tree lives in `data-spec`; on a server re-render (a new generation)
  // the attribute changes, so re-mount with the fresh spec.
  async updated() {
    await this._render()
  },

  destroyed() {
    if (this._unmount) this._unmount()
  },

  async _render() {
    const moduleUrl = this.el.dataset.helloModuleUrl
    if (!moduleUrl) {
      console.error("HelloRenderer missing data-hello-module-url")
      return
    }

    try {
      const mod = await import(/* @vite-ignore */ moduleUrl)
      if (this._unmount) this._unmount()
      this._unmount = mod.mountHello(this.el, {
        spec: parseJson(this.el.dataset.spec, null),
      })
    } catch (error) {
      console.error("HelloRenderer failed to mount", error)
      this.el.dataset.helloMountError = "true"
    }
  },
}

function parseJson(value, fallback) {
  if (!value) return fallback

  try {
    return JSON.parse(value)
  } catch (_error) {
    return fallback
  }
}
