import {defineCatalog} from "@json-render/core"
import {schema} from "@json-render/react/schema"
import {z} from "zod"

// The hello component catalog — the SAME `@json-render`-constrained set the
// server's `EzagentPluginHello.Spec` validates (page/section/card/heading/text/
// button/image). Props are lenient (nullable/optional) because the spec is
// LLM-authored JSON round-tripped through the Surface as string-keyed maps; a
// missing prop must degrade, not reject. This is the single catalog both the
// operator island (this Vite bundle) and — after the customer migration — the
// customer SPA render from.
const opt = z.string().nullable().optional()
const optNum = z.union([z.number(), z.string()]).nullable().optional()

export const catalog = defineCatalog(schema, {
  components: {
    page: {props: z.object({title: opt}), description: "The page root: a title + a vertical stack of children."},
    section: {props: z.object({layout: opt}), description: "A grouping section; layout 'stack' (default) or 'grid'."},
    card: {props: z.object({title: opt}), description: "A titled card wrapping its children."},
    heading: {props: z.object({text: opt, level: optNum}), description: "A heading; level 1–6 (default 2)."},
    text: {props: z.object({text: opt}), description: "A paragraph of text."},
    button: {props: z.object({label: opt, href: opt}), description: "A link when href is set, else a plain button."},
    image: {props: z.object({src: opt, alt: opt}), description: "A responsive image."},
  },
  actions: {},
})
