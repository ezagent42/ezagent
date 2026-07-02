// The external-viewer-surface page renderer — now on the OFFICIAL Vercel
// `@json-render/shadcn` catalog (36 shadcn components: Stack/Grid/Card/Heading/
// Text/Button/Tabs/Accordion/Carousel/…). The AI generates a tree of these
// nodes; we render it with the real @json-render engine + shadcn registry.
//
// Convention (from @json-render/shadcn): leaf nodes carry their content in PROPS
// (Heading.text, Text.text, Button.label, Image.src); containers (Stack/Grid/
// Card/Tabs/…) take a `default` slot = the node's `children`. Styling comes from
// the shadcn theme (CSS vars in viewer.css) + each node's optional `className`.
import React from "react"
import {Renderer, JSONUIProvider, defineRegistry} from "@json-render/react"
import {schema} from "@json-render/react/schema"
import {defineCatalog, nestedToFlat} from "@json-render/core"
import {shadcnComponentDefinitions} from "@json-render/shadcn/catalog"
import {shadcnComponents} from "@json-render/shadcn"
import {normalizeSpec} from "./catalog_normalize.mjs"

const h = React.createElement

const catalog = defineCatalog(schema, {components: shadcnComponentDefinitions, actions: {}})

// --- Real Tabs content-switching (override) ---------------------------------
// The stock `@json-render/shadcn` Tabs renders the trigger labels from the
// `tabs` prop but drops ALL default-slot `children` into the tab body
// unconditionally (it never wraps them in per-tab TabsContent panels), so every
// tab's content stacks together and clicking a trigger switches nothing. This
// self-contained override restores true switching with the documented
// convention **child[i] ↔ tabs[i]**: the i-th default-slot child is the panel
// for the i-th `tabs` entry; only the active panel is shown. Pure React (no
// radix/shadcn primitive import) so it always bundles. Emits shadcn-style
// `data-slot`/`data-state` attributes + `jr-tabs*` classes for theming.
function TabsSwitch({props, children}) {
  const tabs = Array.isArray(props && props.tabs) ? props.tabs : []
  const kids = React.Children.toArray(children)
  const valOf = (t, i) => (t && t.value != null ? String(t.value) : String(i))
  const initial =
    (props && props.defaultValue != null && String(props.defaultValue)) ||
    (props && props.value != null && String(props.value)) ||
    (tabs[0] ? valOf(tabs[0], 0) : "0")
  const [active, setActive] = React.useState(initial)
  const rootRef = React.useRef(null)
  // External trigger: a Button elsewhere on the page (e.g. a hero CTA carrying
  // `onClickUrl: "#<value>"`) dispatches `jr-tab-switch`. If the requested value
  // is one of THIS Tabs' values, activate it and scroll this tab bar into view.
  // Lets an off-screen CTA both switch the tab AND bring the tab section on
  // screen — the W4 "看看进度 → 研发进度 tab" flow.
  React.useEffect(() => {
    const owned = tabs.map((t, i) => valOf(t, i))
    const onSwitch = (e) => {
      const val = e && e.detail && e.detail.value != null ? String(e.detail.value) : null
      if (val == null || owned.indexOf(val) === -1) return
      setActive(val)
      const el = rootRef.current
      if (el && typeof el.scrollIntoView === "function") {
        el.scrollIntoView({behavior: "smooth", block: "start"})
      }
    }
    window.addEventListener("jr-tab-switch", onSwitch)
    return () => window.removeEventListener("jr-tab-switch", onSwitch)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(tabs)])
  return h(
    "div",
    {className: "jr-tabs", "data-slot": "tabs", ref: rootRef},
    h(
      "div",
      {className: "jr-tabs-list", "data-slot": "tabs-list", role: "tablist"},
      tabs.map((t, i) => {
        const val = valOf(t, i)
        const on = active === val
        return h(
          "button",
          {
            key: val,
            type: "button",
            role: "tab",
            className: "jr-tab",
            "data-slot": "tabs-trigger",
            "data-state": on ? "active" : "inactive",
            "aria-selected": on,
            onClick: () => setActive(val),
          },
          t && t.label != null ? t.label : val,
        )
      }),
    ),
    tabs.map((t, i) => {
      const val = valOf(t, i)
      const on = active === val
      return h(
        "div",
        {
          key: val,
          role: "tabpanel",
          className: "jr-tabs-content",
          "data-slot": "tabs-content",
          "data-state": on ? "active" : "inactive",
          hidden: !on,
        },
        kids[i] != null ? kids[i] : null,
      )
    }),
  )
}

// --- Button navigation (override) -------------------------------------------
// The stock `@json-render/shadcn` Button only emits a `press` action (no href),
// so a body-authored CTA can't navigate anywhere on a static viewer page. This
// wrapper adds an optional `onClickUrl` (alias `href`) prop, honored on press:
//   - `#<value>`  → dispatch `jr-tab-switch` {value} (TabsSwitch listens; W4)
//   - anything else → open in a new tab (external links / GitHub; W3)
// It delegates rendering to the real shadcn Button (same `data-slot=button`
// markup, so existing theme CSS + `:first-child`/`:last-child` selectors still
// apply); a Button with no url behaves exactly as before.
function ButtonNav({props, emit}) {
  const url = props && (props.onClickUrl || props.href || props.url)
  const handleEmit = (name) => {
    if (name === "press" && url) {
      if (String(url).charAt(0) === "#") {
        window.dispatchEvent(
          new CustomEvent("jr-tab-switch", {detail: {value: String(url).slice(1)}}),
        )
      } else {
        window.open(String(url), "_blank", "noopener,noreferrer")
      }
      return
    }
    if (typeof emit === "function") emit(name)
  }
  return h(shadcnComponents.Button, {props, emit: handleEmit})
}

const {registry} = defineRegistry(catalog, {
  components: {...shadcnComponents, Tabs: TabsSwitch, Button: ButtonNav},
})

function Unknown({element}) {
  return h(
    "div",
    {className: "rounded-lg border border-dashed px-3 py-2 text-sm italic opacity-50"},
    "Unsupported node: " + String(element && element.type),
  )
}

export function JsonRenderPage({page}) {
  const safe = page && typeof page === "object" ? normalizeSpec(page) : null
  const spec = safe ? nestedToFlat(safe) : null
  return h(JSONUIProvider, {registry}, h(Renderer, {spec, registry, fallback: Unknown}))
}
