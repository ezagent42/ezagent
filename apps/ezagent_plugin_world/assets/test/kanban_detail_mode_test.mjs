import assert from "node:assert/strict"
import fs from "node:fs"

const main = fs.readFileSync(new URL("../src/main.tsx", import.meta.url), "utf8")

assert.equal(main.includes('mode={context.state.kanban_uri ? "operate" : "config"}'), true)
