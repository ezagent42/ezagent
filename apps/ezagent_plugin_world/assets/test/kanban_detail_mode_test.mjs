import assert from "node:assert/strict"
import fs from "node:fs"

const kanban = fs.readFileSync(new URL("../../../ezagent_plugin_kanban/assets/src/Kanban.tsx", import.meta.url), "utf8")
const worldPage = fs.readFileSync(new URL("../../../ezagent_plugin_kanban/assets/src/world_page.tsx", import.meta.url), "utf8")

assert.equal(worldPage.includes('mode={pageState.kanban_uri ? "operate" : "config"}'), true)
assert.match(kanban, /data-world-kanban-workbench/)
assert.match(kanban, /data-world-kanban-canvas/)
assert.match(kanban, /data-world-kanban-empty-tree/)
