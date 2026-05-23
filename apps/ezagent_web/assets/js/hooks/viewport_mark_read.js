// PR-2 of Read Receipts rollout — IntersectionObserver hook that
// fires `mark_displayed` LV event when a chat message enters viewport.
//
// Per SPEC `docs/superpowers/specs/2026-05-23-read-receipts.md` §4.1:
// `:displayed` is the medium-confidence source (between `:delivered`
// and `:read`); fires when the UI has actually rendered the message
// in the user's viewport (not just dispatched server-side).
//
// ## Usage
//
//     <div
//       :for={{dom_id, row} <- @messages_stream}
//       id={dom_id}
//       phx-hook="ViewportMarkRead"
//       data-msg-id={row.id}
//       ...
//     />
//
// On mount, the hook creates ONE IntersectionObserver per element.
// When the element becomes ≥50% visible AND has been so for ≥250ms
// (debounce — guards against scroll-pass-through firing), it pushes
// `mark_displayed` with `{msg_id: data-msg-id}` to the LV. The LV
// handles by calling `Ezagent.Chat.ReadMarker.mark(session_uri,
// user_uri, msg_id, :displayed)`.
//
// Idempotent: the observer fires `:displayed` only ONCE per element
// per mount (we disconnect after first hit). Subsequent re-scrolls
// don't re-emit (the marker is already :displayed; further bumps
// are wasted RPC).

const VISIBILITY_THRESHOLD = 0.5
const DWELL_MS = 250

export const ViewportMarkRead = {
  mounted() {
    this._timer = null
    this._observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.intersectionRatio >= VISIBILITY_THRESHOLD) {
            // start dwell timer
            if (this._timer == null) {
              this._timer = setTimeout(() => {
                const msgId = this.el.dataset.msgId
                if (msgId) {
                  this.pushEvent("mark_displayed", { msg_id: msgId })
                }
                // fire-once: disconnect observer
                this._observer.disconnect()
                this._observer = null
                this._timer = null
              }, DWELL_MS)
            }
          } else {
            // moved out of viewport before dwell completed — cancel
            if (this._timer != null) {
              clearTimeout(this._timer)
              this._timer = null
            }
          }
        }
      },
      { threshold: VISIBILITY_THRESHOLD }
    )

    this._observer.observe(this.el)
  },

  destroyed() {
    if (this._timer != null) {
      clearTimeout(this._timer)
      this._timer = null
    }
    if (this._observer != null) {
      this._observer.disconnect()
      this._observer = null
    }
  },
}
