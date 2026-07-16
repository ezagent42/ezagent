const NAV_TYPES = new Set(["switch_tab", "scroll_to", "open_url"])

export function latestUnseenNavMessage(messages, seenIds) {
  if (!Array.isArray(messages)) return null

  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i]
    const nav = message && message.nav
    if (
      message &&
      message.id &&
      !seenIds.has(message.id) &&
      nav &&
      typeof nav === "object" &&
      NAV_TYPES.has(nav.type)
    ) {
      return message
    }
  }

  return null
}
