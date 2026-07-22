import assert from "node:assert/strict"
import fs from "node:fs"

const main = fs.readFileSync(new URL("../src/main.tsx", import.meta.url), "utf8")
const kanban = fs.readFileSync(new URL("../src/components/Kanban.tsx", import.meta.url), "utf8")

assert.equal(main.includes('mode={context.state.kanban_uri ? "operate" : "config"}'), true)
assert.match(kanban, /data-world-kanban-workbench/)
assert.match(kanban, /data-world-kanban-canvas/)
assert.match(kanban, /data-world-kanban-empty-tree/)
