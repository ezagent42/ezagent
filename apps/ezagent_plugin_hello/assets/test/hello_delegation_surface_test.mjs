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
assert.match(viewer, /hello_kanban_receipt/)
assert.match(viewer, /待派/)
assert.match(viewer, /松耦合，非最终挂载/)
assert.match(viewer, /delegationEndpoint/)
assert.match(viewer, /name: "session_uri"/)
assert.match(viewer, /name: "instruction"/)
assert.match(viewer, /jr-composer-focus/)
assert.match(viewer, /focus\(\)/)
assert.doesNotMatch(viewer, /kanban\.add_node/)
assert.match(controller, /data-hello-delegation-endpoint/)

const seed = JSON.parse(readFileSync(new URL("../../priv/seed_page/body.json", import.meta.url), "utf8"))
const serializedSeed = JSON.stringify(seed)
assert.match(serializedSeed, /hello-product-entry/)
assert.match(serializedSeed, /hello-task-cta/)
assert.match(serializedSeed, /hello-coupling-boundary/)
assert.match(serializedSeed, /松耦合，非最终挂载/)

console.log("hello delegation surface contract: ok")
