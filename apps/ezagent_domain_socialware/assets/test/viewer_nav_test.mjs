import assert from "node:assert/strict"
import {latestUnseenNavMessage} from "../js/viewer_nav.mjs"

const seen = new Set(["old"])
const messages = [
  {id: "old", sender: "entity://system/agent/uuid-a", nav: {type: "switch_tab", value: "home"}},
  {id: "receipt", sender: "entity://system/agent/uuid-b", nav: {kind: "hello_kanban_receipt"}},
  {id: "team", sender: "entity://system/agent/uuid-c", nav: {type: "switch_tab", value: "team"}},
]

assert.equal(latestUnseenNavMessage(messages, seen).id, "team")
assert.equal(latestUnseenNavMessage(messages, new Set(["old", "team"])), null)
assert.equal(
  latestUnseenNavMessage([{id: "bad", nav: {type: "run_script", value: "x"}}], new Set()),
  null,
)

console.log("viewer navigation contract: ok")
