import {defineCatalog} from "@json-render/core"
import {schema} from "@json-render/react/schema"
import {shadcnComponentDefinitions} from "@json-render/shadcn/catalog"

// The hello operator-island catalog — the OFFICIAL Vercel `@json-render/shadcn`
// component set (36 components: Stack/Grid/Card/Heading/Text/Button/Badge/Avatar/
// Alert/Accordion/Table/Input/…). This is the SAME set the server's
// `EzagentPluginHello.Spec` (lib/.../spec.ex) validates against — both derive
// from `@json-render/shadcn`, so the frontend catalog == spec.ex's 36 components
// by construction (structural parity, no hand-maintained list to drift).
//
// It is ALSO the same catalog the customer SPA renders from
// (apps/ezagent_domain_socialware/assets/js/catalog_jsonrender.mjs), so the
// OPERATOR preview (this island) and the public /socialware/customer page render
// identically — no more "Unsupported node: Stack" on the old 7-lowercase catalog.
export const catalog = defineCatalog(schema, {
  components: shadcnComponentDefinitions,
  actions: {},
})
