import {defineRegistry} from "@json-render/react"
import {shadcnComponents} from "@json-render/shadcn"
import {catalog} from "./catalog"

// Real shadcn/Tailwind implementations — the OFFICIAL `@json-render/shadcn` React
// components, NOT hand-written inline styles. This is the SAME registry the
// customer SPA uses (catalog_jsonrender.mjs), so the internal preview and the
// public /socialware/customer page render byte-for-byte identically.
//
// The shadcn utility classes + design tokens these components emit are compiled
// into the island's self-contained CSS (`island.css`, injected as a <style> by
// main.tsx) so the island renders correctly inside the world LiveView internal
// shell WITHOUT depending on the world CSS build (and without leaking a global
// Tailwind preflight reset into the console — island.css excludes preflight).
export const {registry} = defineRegistry(catalog, {
  components: shadcnComponents,
})
