import {mountWorld} from "/assets/world/main.js"

const response = await fetch("/fixtures/world.e2e.fixtures.json")
if (!response.ok) throw new Error(`fixture load failed: ${response.status}`)

const contract = await response.json()
const fixtureName = new URLSearchParams(window.location.search).get("fixture") || "sessions"
const fixture = contract.fixtures[fixtureName]
if (!fixture) throw new Error(`unknown World E2E fixture: ${fixtureName}`)

const root = document.querySelector("#world-e2e-root")
if (!(root instanceof HTMLElement)) throw new Error("missing #world-e2e-root")

const listeners = new Map()
const events = []
let contractViolation = null

const onServerEvent = (event, callback) => {
  const callbacks = listeners.get(event) || []
  callbacks.push(callback)
  listeners.set(event, callbacks)
}

const emit = (event, payload) => {
  for (const callback of listeners.get(event) || []) callback(payload)
}

const pushEvent = (event, payload, onReply) => {
  if (
    event === "world:dispatch" &&
    (!payload || typeof payload.action !== "string" || !contract.accepted_actions.includes(payload.action))
  ) {
    contractViolation = payload?.action || "missing action"
  }

  events.push({event, payload})
  onReply?.({ok: true})
}

window.__WORLD_E2E__ = {
  clearEvents() {
    events.length = 0
    contractViolation = null
  },
  contract,
  contractViolation() {
    return contractViolation
  },
  emit,
  events,
  transitionTo(name) {
    const next = contract.fixtures[name]
    if (!next) throw new Error(`unknown World E2E fixture: ${name}`)
    emit("world:state", {...next.state, layout: next.layout})
  },
}

mountWorld(root, {...fixture, pushEvent, onServerEvent})
document.documentElement.dataset.worldE2eReady = "true"
