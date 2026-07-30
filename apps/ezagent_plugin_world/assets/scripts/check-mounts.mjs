#!/usr/bin/env node
// Layer-2 of the two-layer typed-slot gate (handoff §3.2): a JS/TS static check
// that bans top-level world surfaces from mounting except through the layout
// renderer. This is the developer-facing "frontend check"; the authoritative
// CI hard-fail mirror is the Elixir `slot_mount_gate_test.exs` (kept in lockstep
// — change both together).
//
// Run: `pnpm check:mounts` (from assets/). Exits non-zero on any violation.
import {readFileSync, readdirSync} from "node:fs"
import {dirname, join} from "node:path"
import {fileURLToPath} from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const srcDir = join(here, "..", "src")
const componentsDir = join(srcDir, "components")

// Layout-slot Surface components: the renderer's leaves. They may be mounted
// ONLY by the registry-backed renderer in main.tsx.
const SURFACES = [
  "SessionsTable",
  "Conversation",
  "PtyTerminalSurface",
  "AdminSurface",
  "WorkspacePluginSurface",
  "IdentitiesSurface",
]

// Sanctioned `:subcomponent` mounts: a parent surface owning a nested slot,
// marked in the DOM with `data-world-subcomponent`. file => [allowed surfaces].
const SUBCOMPONENT_ALLOWLIST = {"Conversation.tsx": ["PtyTerminalSurface"]}

const errors = []
const read = (p) => readFileSync(p, "utf8")

const mainSrc = read(join(srcDir, "main.tsx"))
const manifest = JSON.parse(read(join(srcDir, "slots.manifest.json")))

const componentFiles = readdirSync(componentsDir).filter(
  (f) => f.endsWith(".tsx") && !f.endsWith(".test.tsx"),
)

// Check 1 — single mount point: createRoot only in main.tsx.
for (const file of componentFiles) {
  if (/\bcreateRoot\s*\(/.test(read(join(componentsDir, file)))) {
    errors.push(`${file}: calls createRoot — surfaces must mount via main.tsx's renderer, not their own React root`)
  }
}

// Check 2 — no surface bypass: a Surface imported outside main.tsx is a registry
// bypass unless it is a declared subcomponent of that file.
for (const file of componentFiles) {
  const src = read(join(componentsDir, file))
  const allowed = SUBCOMPONENT_ALLOWLIST[file] || []
  for (const surface of SURFACES) {
    const importsIt = new RegExp(`import[^\\n]*\\b${surface}\\b[^\\n]*from`).test(src)
    if (importsIt && !allowed.includes(surface)) {
      errors.push(
        `${file}: imports ${surface} — only main.tsx's renderer may mount a layout-slot surface ` +
          `(if this is a parent-owned nested slot, add it to SUBCOMPONENT_ALLOWLIST and mark it data-world-subcomponent)`,
      )
    }
  }
  // A declared subcomponent must carry the DOM marker.
  for (const surface of allowed) {
    if (!src.includes("data-world-subcomponent")) {
      errors.push(`${file}: declares subcomponent ${surface} but renders no data-world-subcomponent marker`)
    }
  }
}

// Check 3 — family parity: the renderer handles exactly the manifest's families.
// Plugin-page families render through the PLUGIN_PAGE_RENDERERS registry map
// (looked up in the switch default) instead of literal cases — the handled set
// is the union of switch cases and the map's keys (PluginPageRegistry rework).
const switchBody = (() => {
  const start = mainSrc.indexOf("switch (rendererFamily(component.type))")
  const end = mainSrc.indexOf("\nfunction ", start)
  return start === -1 ? "" : mainSrc.slice(start, end === -1 ? undefined : end)
})()
const pluginPageBody = (() => {
  const start = mainSrc.indexOf("const PLUGIN_PAGE_RENDERERS")
  const end = mainSrc.indexOf("\nfunction ", start)
  return start === -1 ? "" : mainSrc.slice(start, end === -1 ? undefined : end)
})()
const switchCases = new Set([...switchBody.matchAll(/case "([a-z_]+)":/g)].map((m) => m[1]))
const pluginPageKeys = new Set([...pluginPageBody.matchAll(/^  ([a-z_]+): \(/gm)].map((m) => m[1]))
const manifestFamilies = new Set(Object.keys(manifest.renderer_families))

for (const key of pluginPageKeys) {
  // A literal case would silently shadow the registry entry (mirrors the
  // SlotRegistry compile-time clash guard).
  if (switchCases.has(key)) errors.push(`main.tsx: plugin page key "${key}" shadowed by a literal switch case`)
}
const rendererCases = new Set([...switchCases, ...pluginPageKeys])

for (const fam of manifestFamilies) {
  if (!rendererCases.has(fam)) errors.push(`main.tsx: no renderer case for manifest family "${fam}"`)
}
for (const fam of rendererCases) {
  if (!manifestFamilies.has(fam)) errors.push(`main.tsx: renderer case "${fam}" is not a manifest renderer family`)
}

// Check 4 — no unknown fallback: the switch default must throw (not render a
// surface). The default branch may first consult PLUGIN_PAGE_RENDERERS, but an
// unregistered family must still end in a throw.
const defaultBranch = switchBody.slice(switchBody.indexOf("default:"))
if (!defaultBranch.includes("throw")) {
  errors.push("main.tsx: renderLayoutComponent default branch must throw on an unknown family (no silent fallback)")
}
if (defaultBranch.includes("Surface")) {
  errors.push("main.tsx: renderLayoutComponent default branch must not render a surface — unknown family = throw")
}
if (!/if \(!spec\) \{[\s\S]*?throw/.test(mainSrc)) {
  errors.push("main.tsx: rendererFamily must throw on an unregistered slot type (no silent fallback)")
}

if (errors.length > 0) {
  console.error("world mount gate FAILED:")
  for (const e of errors) console.error("  - " + e)
  process.exit(1)
}
console.log(`world mount gate OK (${componentFiles.length} components, ${manifestFamilies.size} families)`)
