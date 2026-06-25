import {createRoot, type Root} from "react-dom/client"
import {Renderer, JSONUIProvider, type Spec} from "@json-render/react"
import {nestedToFlat} from "@json-render/core"
import {registry} from "./registry"
// The island's self-contained shadcn stylesheet, imported as a STRING (`?inline`)
// so it ships INSIDE main.js — no separate <link> to wire from the (out-of-scope)
// LiveView. Injected as a scoped <style> below.
import islandCss from "./island.css?inline"

// The island entry. The `HelloRenderer` phx-hook dynamically imports this module
// and calls `mountHello(el, {spec, themeCss})` with the session's approved Surface
// tree (the nested `{type, props, children}` map) and, optionally, the
// per-session CSS theme (`shell_css` from `set_shell`). We flatten the tree
// (`nestedToFlat`) and render it through the SAME `@json-render/shadcn` registry
// as the customer `/socialware/customer` page — identical rendering, no more
// "Unsupported node" fallback.

const roots = new WeakMap<HTMLElement, Root>()

function Unknown({element}: {element: {type?: string}}) {
  return (
    <div className="rounded-md border border-dashed px-3 py-2 text-sm italic opacity-60">
      Unsupported node: {String(element?.type)}
    </div>
  )
}

export function mountHello(
  el: HTMLElement,
  opts: {spec?: Record<string, unknown> | null; themeCss?: string | null} = {},
) {
  roots.get(el)?.unmount()
  const root = createRoot(el)
  roots.set(el, root)

  const tree = opts.spec
  const spec: Spec | null = tree && typeof tree === "object" ? (nestedToFlat(tree) as Spec) : null

  // `JSONUIProvider` sets up the state/visibility/action/validation contexts the
  // `Renderer` (and catalog components) need — rendering `<Renderer>` bare throws
  // "useVisibility must be used within a VisibilityProvider".
  //
  // Structure mirrors the customer SPA's `PureThemePage`: the base shadcn CSS
  // (`islandCss`) + an optional per-session theme (`themeCss`, targets `.page` /
  // shadcn data-slots) are injected as <style>; the spec renders under a `.page`
  // wrapper so a per-session style switch applies here exactly as it does on
  // /socialware/customer.
  root.render(
    <JSONUIProvider registry={registry}>
      <div className="page">
        <style dangerouslySetInnerHTML={{__html: islandCss}} />
        {opts.themeCss ? <style dangerouslySetInnerHTML={{__html: opts.themeCss}} /> : null}
        <Renderer spec={spec} registry={registry} fallback={Unknown} />
      </div>
    </JSONUIProvider>,
  )

  return () => {
    root.unmount()
    roots.delete(el)
  }
}
