// The socialware customer **component catalog** — the single client-side source
// of truth for which `@json-render`-style node types the customer surface may
// render. This is the "Zod catalog" the page-builder spec is constrained to.
//
// ## Why a Zod catalog here (and where the *authoritative* gate lives)
//
// The catalog-constraint safety property — "the AI can only emit nodes from the
// catalog; an out-of-catalog node is rejected, never rendered" — is enforced
// AUTHORITATIVELY on the SERVER, before a spec ever reaches `Behavior.Surface`
// (`EzagentPluginHello.Spec.validate/1`, and each socialware producer's own
// validation). This module is the CLIENT mirror of that catalog: it lets the
// customer SPA flag a tree that does not conform (defense in depth) and is the
// extraction-ready schema a future shared renderer can reuse.
//
// ## Not Vercel `@json-render` (yet) — a deliberate, documented substitution
//
// The handoff names Vercel `@json-render/react` as the renderer. Every published
// version of that package (0.0.1 … 0.19.0) hard-requires **React 19**; this
// substrate — the customer SPA, Sandpack 2.20, and `world` — is entirely **React
// 18**. Adopting the upstream library is therefore a React-19 migration of the
// shipped customer surface, which is out of Phase-0 scope. So Phase 0 ships a
// catalog-faithful renderer (`catalog_render.mjs`) with the SAME contract —
// a Zod-described catalog + fail-closed rendering — on React 18, kept behind a
// clean module boundary so swapping in literal `@json-render` after a React-19
// migration is localized. See the hello migration handoff + the Phase-0 status
// doc.
//
// ## Catalog = superset (one renderer for the whole customer surface)
//
// Per the locked decision "`@json-render` is the sole customer renderer — retire
// `json_render.mjs`, do not run two in parallel", this catalog is the UNION of
// the legacy 5-type set (`container`/`text`/`table`/`code`) that the shipped
// socialware customer SPA used and the hello page-builder set
// (`page`/`section`/`card`/`heading`/`text`/`button`/`image`). One renderer now
// serves every socialware customer surface (advisor's pages and hello's pages).

import {z} from "zod"

// Allowed node types. Legacy socialware set + hello page-builder set (`text` is
// shared). A producer constrains its OWN output to a subset (hello → the
// page-builder set, server-validated in `EzagentPluginHello.Spec`); the shared
// renderer handles the union.
export const CATALOG_TYPES = [
  // hello page-builder set
  "page",
  "section",
  "card",
  "heading",
  "text",
  "button",
  "image",
  // legacy socialware set (kept so existing producers, e.g. advisor, render)
  "container",
  "table",
  "code",
]

// A node = `{type ∈ catalog, props?, children?}`. Unknown extra keys are
// stripped (not rejected) and unknown `props` are passed through — only the
// `type ∈ catalog` constraint is the safety property, mirroring the server's
// `Spec.validate/1`. `children` recurses lazily.
export const nodeSchema = z.lazy(() =>
  z.object({
    type: z.enum(CATALOG_TYPES),
    props: z.record(z.string(), z.unknown()).optional(),
    children: z.array(nodeSchema).optional(),
  })
)

// `true` iff `tree` is a catalog-conforming node tree. Never throws — a malformed
// input is simply `false` (the caller decides how to fail closed). The customer
// SPA uses this for a non-destructive conformance signal; the renderer itself
// fails closed per node, so a single bad node degrades to an "unsupported node"
// placeholder rather than blanking the whole page.
export function isValidTree(tree) {
  try {
    return nodeSchema.safeParse(tree).success
  } catch (_error) {
    return false
  }
}
