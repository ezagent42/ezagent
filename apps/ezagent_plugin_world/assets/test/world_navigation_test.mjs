import assert from "node:assert/strict"
import {worldNavigationTarget} from "../js/world_navigation.js"

function anchor({href, target = "", download = false}) {
  return {
    target,
    getAttribute(name) {
      if (name === "href") return href
      return null
    },
    hasAttribute(name) {
      return name === "download" && download
    },
  }
}

function click(anchorEl, attrs = {}) {
  return {
    button: 0,
    defaultPrevented: false,
    metaKey: false,
    ctrlKey: false,
    shiftKey: false,
    altKey: false,
    target: {
      closest(selector) {
        assert.equal(selector, "a[href]")
        return anchorEl
      },
    },
    ...attrs,
  }
}

const root = {
  contains(node) {
    return node !== outsideAnchor
  },
}

const current = "http://world.localhost:10042/sessions"
const outsideAnchor = anchor({href: "/admin"})

assert.equal(
  worldNavigationTarget(click(anchor({href: "/identities/agents/new"})), root, current),
  "/identities/agents/new"
)

assert.equal(
  worldNavigationTarget(click(anchor({href: "/workspaces/team-alpha/templates/new"})), root, current),
  "/workspaces/team-alpha/templates/new"
)

assert.equal(
  worldNavigationTarget(click(anchor({href: "/sessions?session=session%3A%2F%2Fsystem%2Fdefault%2Fmain"})), root, current),
  "/sessions?session=session%3A%2F%2Fsystem%2Fdefault%2Fmain"
)

assert.equal(
  worldNavigationTarget(
    click(anchor({href: "/admin/sessions/session%3A%2F%2Fsystem%2Fdefault%2Fmain/external_mirror"})),
    root,
    current
  ),
  "/admin/sessions/session%3A%2F%2Fsystem%2Fdefault%2Fmain/external_mirror"
)

assert.equal(worldNavigationTarget(click(anchor({href: "https://example.com/admin"})), root, current), null)
assert.equal(worldNavigationTarget(click(anchor({href: "/uploads/download?token=x"})), root, current), null)
assert.equal(worldNavigationTarget(click(anchor({href: "/admin", target: "_blank"})), root, current), null)
assert.equal(worldNavigationTarget(click(anchor({href: "/admin", download: true})), root, current), null)
assert.equal(worldNavigationTarget(click(anchor({href: "/admin"}), {metaKey: true}), root, current), null)
assert.equal(worldNavigationTarget(click(outsideAnchor), root, current), null)

console.log("world_navigation_test: all assertions passed")
