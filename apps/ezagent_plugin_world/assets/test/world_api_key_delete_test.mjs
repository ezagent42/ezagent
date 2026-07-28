import assert from "node:assert/strict"
import fs from "node:fs"

const identities = fs.readFileSync("apps/ezagent_plugin_world/assets/src/components/Identities.tsx", "utf8")
const main = fs.readFileSync("apps/ezagent_plugin_world/assets/src/main.tsx", "utf8")

// Visible only to an editor, so read-only visitors are not offered a mutation
// they cannot perform.
assert.match(identities, /state\.can_edit && <th className=\{thClass\}>Actions<\/th>/)
assert.match(identities, /state\.can_edit && \([\s\S]*data-world-api-key-delete=\{key\.provider\}/)

// The control is destructive, explicit, and asks for confirmation before an
// event is sent to the LiveView.
assert.match(identities, /variant="danger"/)
assert.match(identities, /Delete the API key for \$\{key\.provider\}\? This cannot be undone\./)
assert.match(
  identities,
  /onDeleteApiKey\?\.\(\{agent_uri: state\.agent_uri, provider: key\.provider\}\)/,
)

// The browser sends only the stable provider identifier; it never sends or
// reconstructs a plaintext key.
assert.match(main, /action: "agent\.api_key\.delete"/)
assert.match(main, /onDeleteApiKey: \(payload\) => \{[\s\S]*args: payload/)
assert.doesNotMatch(main, /agent\.api_key\.delete[\s\S]{0,180}key:/)

console.log("world_api_key_delete_test: all assertions passed")
