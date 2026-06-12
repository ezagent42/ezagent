// Phase 8b — inline @ mention autocomplete for SessionEditor's composer.
//
// The composer's <input> binds this hook. As the operator types, when
// the substring immediately before the caret matches /@(\S*)$/, this
// hook filters `this.members` (passed via data-members JSON) and
// renders a floating popover with up to 5 candidates. Clicking a
// candidate replaces the active `@frag` with `@<full-uri>` + a space.
//
// The popover is a SIBLING element (referenced by data-popover CSS
// selector) so its positioning is independent of the input's flow.
// We use `position: fixed` + viewport-relative coords so it floats
// above the composer regardless of scroll/parent overflow.
//
// No LV roundtrip — entirely client-side. Selection mutates the
// input value with a synthetic input event so LV's phx-change picks
// it up via normal form-state sync.
//
// Username & Auth UI Task 1 (Phase 8c PR-O 2026-05-20) — members are
// now passed as `[{uri, display_name}]` instead of `[uri]` so the
// popover can show the display name primary + URI mono subtitle and
// users can filter by either. Both fields participate in the match
// substring search.
export const MentionAutocomplete = {
  mounted() {
    this.members = JSON.parse(this.el.dataset.members || "[]")
    const popoverSelector = this.el.dataset.popover || "#mention-popover"
    this.popover = document.querySelector(popoverSelector)
    this._activeIndex = 0
    this._matches = []

    this.el.addEventListener("input", () => this.handleInput())
    this.el.addEventListener("keydown", (e) => this.handleKeydown(e))
    this.el.addEventListener("blur", () => {
      // Defer hide so click on popover candidate still fires.
      setTimeout(() => this.hidePopover(), 150)
    })

    // Re-read members when the LV re-renders the input with a new
    // members list (e.g. after member_joined).
    this.handleEvent = this.handleEvent || (() => {})

    // Phase 8c follow-up (Allen 2026-05-20) — Phoenix's DOM patcher
    // leaves inputs with phx-hook alone (hook "owns" the value), so
    // a server-side `to_form(%{text: ""})` after submit doesn't
    // actually clear the browser DOM. The LV pushes a
    // `clear_compose` event on successful send; this hook resets
    // the input value + closes the popover.
    this.handleEvent("clear_compose", () => {
      this.el.value = ""
      this.hidePopover()
    })
  },

  updated() {
    // Members may have changed (member_joined/left). Refresh.
    this.members = JSON.parse(this.el.dataset.members || "[]")
  },

  destroyed() {
    this.hidePopover()
  },

  handleInput() {
    const text = this.el.value
    const caret = this.el.selectionStart || text.length
    const before = text.substring(0, caret)
    const match = /@(\S*)$/.exec(before)

    if (match) {
      const filter = match[1].toLowerCase()
      const matches = this.members
        .map((m) => normalize(m))
        .filter((m) =>
          m.uri.toLowerCase().includes(filter) ||
          (m.display_name && m.display_name.toLowerCase().includes(filter))
        )
        .slice(0, 50)
      this._matches = matches
      this._activeIndex = 0
      this.renderPopover(matches)
    } else {
      this.hidePopover()
    }
  },

  handleKeydown(e) {
    if (!this.popover || this.popover.classList.contains("hidden")) return
    if (this._matches.length === 0) return

    if (e.key === "ArrowDown") {
      e.preventDefault()
      this._activeIndex = (this._activeIndex + 1) % this._matches.length
      this.renderPopover(this._matches)
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      this._activeIndex =
        (this._activeIndex - 1 + this._matches.length) % this._matches.length
      this.renderPopover(this._matches)
    } else if (e.key === "Enter") {
      e.preventDefault()
      // Phase 8c follow-up (Allen 2026-05-20) — selectMention takes a
      // URI string; mouse-click path passes `dataset.uri`. Enter used
      // to pass the whole match OBJECT, which template-literal'd as
      // "[object Object]" into the input — broken mention, message
      // never routed to the named agent.
      this.selectMention(this._matches[this._activeIndex].uri)
    } else if (e.key === "Escape") {
      e.preventDefault()
      this.hidePopover()
    }
  },

  renderPopover(matches) {
    if (!this.popover) return

    if (matches.length === 0) {
      this.hidePopover()
      return
    }

    const rect = this.el.getBoundingClientRect()
    this.popover.style.position = "fixed"
    this.popover.style.left = rect.left + "px"
    this.popover.style.bottom = (window.innerHeight - rect.top + 4) + "px"
    this.popover.style.minWidth = rect.width + "px"
    this.popover.style.maxWidth = "480px"
    // 候选可能很多(loom session 成员数十个)→ 限高 + 滚动,别撑满屏。
    this.popover.style.maxHeight = "320px"
    this.popover.style.overflowY = "auto"

    this.popover.innerHTML = matches
      .map((m, i) => {
        const active = i === this._activeIndex
          ? "bg-blue-50 dark:bg-blue-950 text-blue-800 dark:text-blue-200"
          : "hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-300"
        const primary = m.display_name && m.display_name !== m.uri
          ? `<div class="text-xs font-medium">${escapeText(m.display_name)}</div>` +
            `<div class="text-[10px] font-mono text-zinc-500">${escapeText(m.uri)}</div>`
          : `<div class="text-xs font-mono">${escapeText(m.uri)}</div>`
        return (
          `<button type="button" data-uri="${escapeAttr(m.uri)}" ` +
          `class="block w-full text-left px-2 py-1 ${active}">${primary}</button>`
        )
      })
      .join("")

    Array.from(this.popover.children).forEach((child) => {
      child.addEventListener("mousedown", (e) => {
        e.preventDefault() // keep input focus
        this.selectMention(child.dataset.uri)
      })
    })

    this.popover.classList.remove("hidden")

    // 让上下键选中的项跟随滚动进可视区(候选可能 >可视高度)。
    const activeEl = this.popover.children[this._activeIndex]
    if (activeEl && typeof activeEl.scrollIntoView === "function") {
      activeEl.scrollIntoView({ block: "nearest" })
    }
  },

  selectMention(uri) {
    if (!uri) {
      this.hidePopover()
      return
    }
    // Defensive: a non-string arg means a caller mistake — silently
    // coercing produces "[object Object]" in the input (the
    // 2026-05-20 bug). Crash loudly instead.
    if (typeof uri !== "string") {
      throw new Error(
        `MentionAutocomplete.selectMention expected URI string, got ${typeof uri}: ${JSON.stringify(uri)}`
      )
    }
    const text = this.el.value
    const caret = this.el.selectionStart || text.length
    const before = text.substring(0, caret)
    const after = text.substring(caret)
    const match = /@(\S*)$/.exec(before)

    if (match) {
      const head = before.substring(0, match.index)
      const inserted = `@${uri} `
      const newText = head + inserted + after
      this.el.value = newText
      const newCaret = (head + inserted).length
      this.el.setSelectionRange(newCaret, newCaret)
      this.el.dispatchEvent(new Event("input", { bubbles: true }))
    }
    this.el.focus()
    this.hidePopover()
  },

  hidePopover() {
    if (this.popover) {
      this.popover.classList.add("hidden")
      this.popover.innerHTML = ""
    }
  },
}

function escapeAttr(s) {
  return String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;")
}

function escapeText(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

// Username & Auth UI Task 1 — tolerate both new `{uri, display_name}`
// shape and legacy raw-string shape during rollout. Server always
// sends objects post-PR but tests may inject either.
function normalize(m) {
  if (typeof m === "string") return { uri: m, display_name: null }
  return { uri: m.uri, display_name: m.display_name || null }
}
