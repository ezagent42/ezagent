// V1 UI PR-1 (SPEC §1.2 / §1.4 / §1.6) — client side of the
// `EzagentDomainUi.Primitives.uri_picker/1` component.
//
// The component root carries `phx-hook="UriPicker"`. The mutable
// subtree (dropdown, chips, hidden form inputs) is wrapped in
// `phx-update="ignore"` so a LiveView re-render never wipes
// hook-mutated DOM. The immutable options list rides in the root's
// `data-options` JSON attribute.
//
// Responsibilities:
//   - mounted():  parse data-options, wire the filter input + chip
//     buttons + free-text disclosure, render initial state.
//   - updated():  LiveView pushed a new data-options (workspace
//     switch / reconnect) — re-read options and PRUNE any selection
//     no longer in the option set (SPEC §1.6). A stale pick can never
//     silently survive into a submit.
//
// Client-side filtering is UX only. The server revalidates every
// submitted URI via `Ezagent.UI.UriOptions.valid_for?/4`.

const MAX_RESULTS = 50

export const UriPicker = {
  mounted() {
    this.mode = this.el.dataset.mode || "single"
    this.name = this.el.dataset.name || ""
    this.allowFreetext = this.el.dataset.allowFreetext === "true"

    this.body = this.el.querySelector("[data-uri-picker-body]")
    this.filterInput = this.el.querySelector("[data-uri-picker-filter]")
    this.dropdown = this.el.querySelector("[data-uri-picker-dropdown]")
    this.emptyEl = this.el.querySelector("[data-uri-picker-empty]")
    this.chipsEl = this.el.querySelector("[data-uri-picker-chips]")
    this.freetextDetails = this.el.querySelector("[data-uri-picker-freetext]")
    this.freetextInput = this.el.querySelector("[data-uri-picker-freetext-input]")

    this.options = this._readOptions()
    this.selected = this._readInitialSelection()

    this._wire()
    this._renderChips()
    this._syncHidden()
    this._applyFreetextState()
  },

  updated() {
    // LiveView re-rendered the root and merged a new data-options
    // (data attributes ARE merged through phx-update="ignore"). Drop
    // any selection that is no longer a live option (SPEC §1.6).
    this.options = this._readOptions()
    const uris = new Set(this.options.map((o) => o.uri))
    const before = this.selected.length
    this.selected = this.selected.filter((u) => uris.has(u))

    if (this.selected.length !== before) {
      this._renderChips()
      this._syncHidden()
      if (this.mode === "single") {
        this.filterInput.value = this.selected[0] || ""
      }
    }
  },

  // --- setup ---------------------------------------------------------------

  _readOptions() {
    try {
      const raw = JSON.parse(this.el.dataset.options || "[]")
      return Array.isArray(raw) ? raw : []
    } catch (_e) {
      return []
    }
  },

  _readInitialSelection() {
    // The server pre-seeds hidden inputs (no-JS dead-render). Trust
    // them as the starting selection; updated() prunes stale ones.
    return Array.from(
      this.body.querySelectorAll("[data-uri-picker-hidden]")
    ).map((i) => i.value).filter((v) => v)
  },

  _wire() {
    this.filterInput.addEventListener("input", () => this._renderDropdown())
    this.filterInput.addEventListener("focus", () => this._renderDropdown())
    this.filterInput.addEventListener("keydown", (e) => this._onKeydown(e))
    // Delay hiding so a click on a dropdown row registers first.
    this.filterInput.addEventListener("blur", () => {
      setTimeout(() => this._hideDropdown(), 150)
    })

    this.dropdown.addEventListener("mousedown", (e) => {
      const row = e.target.closest("[data-uri]")
      if (row) {
        e.preventDefault()
        this._pick(row.dataset.uri)
      }
    })

    if (this.chipsEl) {
      this.chipsEl.addEventListener("click", (e) => {
        const remove = e.target.closest("[data-uri-picker-chip-remove]")
        if (remove) {
          e.preventDefault()
          this._unpick(remove.dataset.uri)
        }
      })
    }

    if (this.allowFreetext && this.freetextDetails) {
      this.freetextDetails.addEventListener("toggle", () =>
        this._applyFreetextState()
      )
    }
  },

  // --- filtering + dropdown ------------------------------------------------

  _filtered() {
    const q = (this.filterInput.value || "").trim().toLowerCase()
    const chosen = new Set(this.selected)
    let list = this.options.filter((o) => !chosen.has(o.uri))
    if (q) {
      list = list.filter((o) => {
        const label = (o.label || "").toLowerCase()
        const uri = (o.uri || "").toLowerCase()
        return label.includes(q) || uri.includes(q)
      })
    }
    return list.slice(0, MAX_RESULTS)
  },

  _renderDropdown() {
    const list = this._filtered()
    this.dropdown.innerHTML = ""

    if (list.length === 0) {
      this._hideDropdown()
      this.emptyEl.classList.remove("hidden")
      return
    }

    this.emptyEl.classList.add("hidden")
    for (const opt of list) {
      this.dropdown.appendChild(this._row(opt))
    }
    this.dropdown.classList.remove("hidden")
  },

  _row(opt) {
    const li = document.createElement("li")
    li.dataset.uri = opt.uri
    li.className =
      "flex flex-col gap-0.5 px-2 py-1.5 cursor-pointer hover:bg-zinc-100 dark:hover:bg-zinc-800"

    const top = document.createElement("div")
    top.className = "flex items-center gap-1.5"

    const label = document.createElement("span")
    label.className = "font-medium text-zinc-900 dark:text-zinc-100"
    label.textContent = opt.label || opt.uri
    top.appendChild(label)

    const badgeText = opt.flavor || opt.kind
    if (badgeText) {
      const badge = document.createElement("span")
      badge.className =
        "px-1 py-0.5 rounded text-[9px] uppercase tracking-wide bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-400"
      badge.textContent = badgeText
      top.appendChild(badge)
    }

    const uri = document.createElement("div")
    uri.className = "font-mono text-[10px] text-zinc-500 dark:text-zinc-400"
    uri.textContent = opt.uri

    li.appendChild(top)
    li.appendChild(uri)
    return li
  },

  _hideDropdown() {
    this.dropdown.classList.add("hidden")
    this.emptyEl.classList.add("hidden")
  },

  _onKeydown(e) {
    if (e.key === "Enter") {
      const first = this._filtered()[0]
      if (first) {
        e.preventDefault()
        this._pick(first.uri)
      }
    } else if (e.key === "Escape") {
      this._hideDropdown()
    }
  },

  // --- selection -----------------------------------------------------------

  _pick(uri) {
    if (!uri) return
    if (this.mode === "single") {
      this.selected = [uri]
      this.filterInput.value = uri
    } else {
      if (!this.selected.includes(uri)) this.selected.push(uri)
      this.filterInput.value = ""
    }
    this._hideDropdown()
    this._renderChips()
    this._syncHidden()
  },

  _unpick(uri) {
    this.selected = this.selected.filter((u) => u !== uri)
    if (this.mode === "single") this.filterInput.value = ""
    this._renderChips()
    this._syncHidden()
  },

  _renderChips() {
    if (this.mode !== "multi" || !this.chipsEl) return
    this.chipsEl.innerHTML = ""
    for (const uri of this.selected) {
      this.chipsEl.appendChild(this._chip(uri))
    }
  },

  _chip(uri) {
    const span = document.createElement("span")
    span.dataset.uriPickerChip = ""
    span.className =
      "inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[11px] font-mono bg-zinc-100 dark:bg-zinc-900 text-zinc-700 dark:text-zinc-300 border border-zinc-200 dark:border-zinc-800"

    const label = document.createElement("span")
    label.textContent = uri
    span.appendChild(label)

    const btn = document.createElement("button")
    btn.type = "button"
    btn.dataset.uriPickerChipRemove = ""
    btn.dataset.uri = uri
    btn.className =
      "text-zinc-400 hover:text-rose-600 dark:hover:text-rose-400"
    btn.setAttribute("aria-label", "Remove")
    btn.textContent = "✕"
    span.appendChild(btn)

    const hidden = document.createElement("input")
    hidden.type = "hidden"
    hidden.name = this.name + "[]"
    hidden.value = uri
    hidden.dataset.uriPickerHidden = ""
    span.appendChild(hidden)

    return span
  },

  // Rebuild the picker's hidden inputs from `this.selected`. For
  // :single this is the one `name` input; for :multi each chip owns
  // its own `name[]` input (built in _chip), so we only refresh the
  // single-mode input here.
  _syncHidden() {
    if (this.mode !== "single") return
    let hidden = this.body.querySelector(
      'input[data-uri-picker-hidden][type="hidden"]'
    )
    if (!hidden) {
      hidden = document.createElement("input")
      hidden.type = "hidden"
      hidden.name = this.name
      hidden.dataset.uriPickerHidden = ""
      this.body.insertBefore(hidden, this.body.firstChild)
    }
    hidden.value = this.selected[0] || ""
  },

  // --- free-text disclosure (SPEC §1.4) ------------------------------------

  // Exactly one source submits. When the <details> is OPEN, the
  // picker's hidden inputs are disabled (excluded from submit) and
  // the free-text input is enabled. When CLOSED, the reverse.
  _applyFreetextState() {
    if (!this.allowFreetext || !this.freetextDetails) return
    const open = this.freetextDetails.open

    for (const i of this.body.querySelectorAll("[data-uri-picker-hidden]")) {
      i.disabled = open
    }
    if (this.freetextInput) {
      this.freetextInput.disabled = !open
    }
  },
}
