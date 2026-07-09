import assert from "node:assert/strict"
import {
  isPrimaryNavActive,
  pageTitleForComponent,
  primaryNavItems,
  sectionRoot,
} from "../js/world_ia.js"

assert.deepEqual(primaryNavItems().map((item) => item.label), ["Chat", "Agents", "Manage", "Overview"])
assert.deepEqual(primaryNavItems().map((item) => item.href), ["/sessions", "/identities/agents", "/workspaces", "/overview"])

// `/` stays the Chat default landing; Overview is a NON-default entry at
// /overview (not the `/` first screen).
assert.equal(isPrimaryNavActive("/", "/sessions"), true)
assert.equal(isPrimaryNavActive("/sessions", "/sessions"), true)
assert.equal(isPrimaryNavActive("/sessions?session=x", "/sessions"), true)
assert.equal(isPrimaryNavActive("/overview", "/overview"), true)
assert.equal(isPrimaryNavActive("/", "/overview"), false)
assert.equal(isPrimaryNavActive("/identities/agents/new", "/identities/agents"), true)
assert.equal(isPrimaryNavActive("/admin/routing", "/workspaces"), true)
assert.equal(isPrimaryNavActive("/plugins/feishu/bindings", "/workspaces"), true)
assert.equal(isPrimaryNavActive("/profile", "/workspaces"), false)

assert.deepEqual(sectionRoot("/identities/agents/new"), {label: "Agents", href: "/identities/agents"})
assert.deepEqual(sectionRoot("/plugins/kanban"), {label: "Manage", href: "/workspaces"})
assert.deepEqual(sectionRoot("/admin/settings"), {label: "Manage", href: "/workspaces"})
assert.deepEqual(sectionRoot("/sessions"), {label: "Chat", href: "/sessions"})

assert.equal(pageTitleForComponent("overview"), "Overview")
assert.equal(pageTitleForComponent("sessions_table"), "Chat")
assert.equal(pageTitleForComponent("conversation"), "Chat")
assert.equal(pageTitleForComponent("profile"), "Profile")
assert.equal(pageTitleForComponent("workspace_template_new"), "New template")

console.log("world_ia_test: all assertions passed")
