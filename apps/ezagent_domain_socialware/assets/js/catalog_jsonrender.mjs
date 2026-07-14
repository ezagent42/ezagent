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
  // When the triggers live elsewhere (e.g. the nav tabs), skip rendering this
  // Tabs node's own trigger row entirely — switching is driven by `jr-tab-switch`.
  const hideList = !!(props && props.hideList)
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
      // Nav-driven tabs (hideList) are full-page panels: switch only, don't scroll
      // to a position (用户 spec — "切换 tab, 不是滚动到对应位置").
      if (hideList) return
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
    hideList
      ? null
      : h(
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
//   - `@login`    → AUTH button: go to /login?return_to=… when logged out, and
//                   swap its own label to the username when logged in (reads the
//                   viewer identity `viewer_app.js` publishes on `jr-viewer`)
//   - `@composer` → focus the viewer's single persistent prompt composer
//   - anything else → open in a new tab (external links / GitHub; W3)
// A Button also carrying `navTab: "<value>"` is a NAV TAB: besides dispatching
// the switch, it LISTENS to `jr-tab-switch` and toggles its own `.active` class
// so the nav reflects which section is showing (nav ↔ Tabs panel in sync).
// It delegates rendering to the real shadcn Button (same `data-slot=button`
// markup, so existing theme CSS still applies); a plain Button is unchanged.
function ButtonNav({props, emit}) {
  const url = props && (props.onClickUrl || props.href || props.url)
  const navTab = props && props.navTab != null ? String(props.navTab) : null
  const isAuth = url === "@login"

  // Nav-tab active state — synced to the shared `jr-tab-switch` event so clicking
  // ANY tab (or the hero CTA) updates every nav tab's highlight consistently.
  const [tabActive, setTabActive] = React.useState(!!(props && props.navActive))
  React.useEffect(() => {
    if (!navTab) return
    const onSwitch = (e) => {
      const v = e && e.detail && e.detail.value != null ? String(e.detail.value) : null
      if (v != null) setTabActive(v === navTab)
    }
    window.addEventListener("jr-tab-switch", onSwitch)
    return () => window.removeEventListener("jr-tab-switch", onSwitch)
  }, [navTab])

  // Auth state — the viewer identity published by viewer_app.js.
  const [viewer, setViewer] = React.useState(
    () => (typeof window !== "undefined" && window.__ezViewer) || null,
  )
  React.useEffect(() => {
    if (!isAuth) return
    const on = (e) => setViewer(e.detail || null)
    window.addEventListener("jr-viewer", on)
    if (typeof window !== "undefined" && window.__ezViewer) setViewer(window.__ezViewer)
    return () => window.removeEventListener("jr-viewer", on)
  }, [isAuth])

  const loggedIn = !!(viewer && viewer.logged_in)

  // Navigate/switch/login on click (used by the plain nav elements below).
  const doNav = () => {
    if (isAuth) {
      // Same effect as the composer bar's 登录 — only when NOT already logged in.
      if (!loggedIn) {
        const back = window.location.pathname + window.location.search
        window.location.href = "/login?return_to=" + encodeURIComponent(back)
      }
      return
    }
    if (url === "@composer") {
      window.dispatchEvent(new CustomEvent("jr-composer-focus"))
      return
    }
    if (url && String(url).charAt(0) === "#") {
      window.dispatchEvent(
        new CustomEvent("jr-tab-switch", {detail: {value: String(url).slice(1)}}),
      )
    } else if (url) {
      window.open(String(url), "_blank", "noopener,noreferrer")
    }
  }

  // NAV TAB → a real tab-trigger pill (data-slot=tabs-trigger), NOT a shadcn
  // Button variant. This reuses the pill-group look the user picked (theme styles
  // `.nav-tab-trigger` / `[data-state=active]`) instead of fighting the Button's
  // Tailwind variant classes (which rendered every tab solid blue).
  if (navTab) {
    return h(
      "button",
      {
        type: "button",
        className: "nav-tab-trigger",
        "data-slot": "tabs-trigger",
        "data-state": tabActive ? "active" : "inactive",
        onClick: doNav,
      },
      props && props.label != null ? props.label : navTab,
    )
  }

  // AUTH → login pill when logged out; a clean username pill when logged in
  // (fully theme-controlled, no shadcn variant baggage).
  if (isAuth) {
    return h(
      "button",
      {
        type: "button",
        className: loggedIn ? "nav-auth is-authed" : "nav-auth",
        onClick: doNav,
        title: loggedIn ? "已登录" : "登录",
      },
      loggedIn
        ? (viewer && viewer.name) || "已登录"
        : (props && props.label) || "登录 · Login",
    )
  }

  // Plain CTA / external link → delegate to the real shadcn Button (unchanged).
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
