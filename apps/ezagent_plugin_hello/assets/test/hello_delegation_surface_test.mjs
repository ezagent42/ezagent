import assert from "node:assert/strict"
import {readFileSync} from "node:fs"

const viewer = readFileSync(
  new URL("../../../ezagent_domain_socialware/assets/js/viewer_app.js", import.meta.url),
  "utf8",
)
const controller = readFileSync(
  new URL("../../../ezagent_web/lib/ezagent_web/controllers/socialware/external_feed_controller.ex", import.meta.url),
  "utf8",
)

assert.match(viewer, /id: "hello-prompt-form"/)
assert.match(viewer, /id: "hello-delegate-login"/)
assert.match(viewer, /id: "hello-kanban-result"/)
assert.match(viewer, /delegationEndpoint/)
assert.match(viewer, /name: "session_uri"/)
assert.match(viewer, /name: "instruction"/)
assert.doesNotMatch(viewer, /kanban\.add_node/)
assert.match(controller, /data-hello-delegation-endpoint/)

console.log("hello delegation surface contract: ok")
