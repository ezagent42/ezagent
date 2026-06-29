// The socialware customer **page renderer** — the catalog-constrained,
// fail-closed renderer that turns a `Behavior.Surface` page tree (the
// `@json-render`-style `{type, props, children}` spec) into React elements for
// the anonymous-visitor customer surface.
//
// This is the successor to (and retirement of) `json_render.mjs`: per the locked
// decision, ONE renderer now serves the whole customer surface. It renders the
// superset catalog declared in `catalog.mjs` (legacy `container`/`text`/`table`/
// `code` + the hello `page`/`section`/`card`/`heading`/`text`/`button`/`image`
// set). An out-of-catalog node falls closed to an "unsupported node" placeholder
// — the same per-node safety the old renderer had — so a single bad node never
// blanks the page.
//
// Why React 18 + hand-rolled (not Vercel `@json-render/react`): the upstream
// library requires React 19; this substrate is React 18. See `catalog.mjs`'s
// header for the full rationale. The contract (catalog + fail-closed render) is
// faithful and the module boundary is clean for a later swap.
//
// The legacy `container`/`text`/`table`/`code`/`__unknown` components below are
// preserved VERBATIM from `json_render.mjs` — the renderer-contract test and the
// agent-browser E2E key off their `sw-*` classes, root element types, and the
// `#36` keyless-child regression fix (`child.key ?? index`, which keeps index 0).

export function renderJsonNode(React, node, registry) {
  if (!node || typeof node !== "object") {
    return React.createElement("div", {"data-node-type": "invalid"}, "Unsupported node")
  }

  const type = typeof node.type === "string" ? node.type : "invalid"
  const component = registry[type] || registry.__unknown
  return React.createElement(component, {
    key: node.key ?? undefined,
    nodeType: type,
    props: node.props || {},
    children: node.children || [],
    registry,
  })
}

export function renderTree(React, tree, registry) {
  return renderJsonNode(React, tree, registry)
}

export function createBaseRegistry(React, Sandpack) {
  return {
    // hello page-builder set
    page: PageNode(React),
    section: SectionNode(React),
    card: CardNode(React),
    heading: HeadingNode(React),
    button: ButtonNode(React),
    image: ImageNode(React),
    // legacy socialware set (verbatim contract)
    container: Container(React),
    text: TextNode(React),
    table: TableNode(React),
    code: CodeNode(React, Sandpack),
    __unknown: UnknownNode(React),
  }
}

// --- hello page-builder set -------------------------------------------------

// `page` — the document root: an optional title heading + a vertical stack of
// children. Maps to the hello catalog `page` (props.title).
function PageNode(React) {
  return function PageJsonNode({props, children, registry}) {
    const title = String(props.title || "")
    const header = title
      ? [
          React.createElement(
            "h1",
            {
              key: "__title",
              className:
                "sw-page-title text-2xl font-semibold tracking-tight text-foreground",
            },
            title
          ),
        ]
      : []

    return React.createElement(
      "main",
      {className: "sw-page flex flex-col gap-6"},
      ...header,
      ...children.map((child, index) =>
        renderJsonNode(React, {...child, key: child.key ?? index}, registry)
      )
    )
  }
}

// `section` — a grouping container with `stack` (default) or `grid` layout,
// mirroring the legacy `container` layout contract but without the card chrome.
function SectionNode(React) {
  return function SectionJsonNode({props, children, registry}) {
    const layout = props.layout === "grid" ? "grid" : "stack"
    const layoutClasses =
      layout === "grid"
        ? "grid grid-cols-1 gap-4 sm:grid-cols-2"
        : "flex flex-col gap-4"

    return React.createElement(
      "section",
      {className: `sw-section sw-section-${layout} ${layoutClasses}`},
      children.map((child, index) =>
        renderJsonNode(React, {...child, key: child.key ?? index}, registry)
      )
    )
  }
}

// `card` — a titled shadcn-token card wrapping its children (props.title).
function CardNode(React) {
  return function CardJsonNode({props, children, registry}) {
    const title = String(props.title || "")
    const header = title
      ? [
          React.createElement(
            "h2",
            {
              key: "__title",
              className: "sw-card-title text-base font-semibold text-card-foreground",
            },
            title
          ),
        ]
      : []

    return React.createElement(
      "div",
      {className: "sw-card rounded-[var(--radius)] bg-card shadow-[var(--shadow-card)]"},
      React.createElement(
        "div",
        {className: "flex flex-col gap-3 p-4 text-card-foreground"},
        ...header,
        ...children.map((child, index) =>
          renderJsonNode(React, {...child, key: child.key ?? index}, registry)
        )
      )
    )
  }
}

// `heading` — an `h1`–`h6` (props.level clamped 1..6, default 2; props.text).
function HeadingNode(React) {
  return function HeadingJsonNode({props}) {
    const level = clampLevel(props.level)
    const sizes = {
      1: "text-2xl",
      2: "text-xl",
      3: "text-lg",
      4: "text-base",
      5: "text-sm",
      6: "text-xs",
    }
    return React.createElement(
      `h${level}`,
      {
        className: `sw-heading sw-heading-${level} font-semibold tracking-tight text-foreground ${sizes[level]}`,
      },
      String(props.text || "")
    )
  }
}

// `button` — an anchor when `props.href` is present (a link/CTA), else a plain
// button. Customer surface is read-only, so a hrefless button is non-interactive
// by design (no client action wiring in Phase 0).
function ButtonNode(React) {
  return function ButtonJsonNode({props}) {
    const label = String(props.label || "")
    const href = typeof props.href === "string" ? props.href : ""

    if (href) {
      return React.createElement(
        "a",
        {
          className:
            "sw-button inline-flex h-8 items-center justify-center rounded-full bg-primary px-3 text-sm font-medium text-primary-foreground shadow-[var(--shadow-soft)] transition hover:bg-primary/90",
          href,
        },
        label
      )
    }

    return React.createElement(
      "button",
      {
        className:
          "sw-button inline-flex h-8 items-center justify-center rounded-full bg-primary px-3 text-sm font-medium text-primary-foreground shadow-[var(--shadow-soft)] transition hover:bg-primary/90",
        type: "button",
      },
      label
    )
  }
}

// `image` — a responsive image (props.src, props.alt).
function ImageNode(React) {
  return function ImageJsonNode({props}) {
    const src = typeof props.src === "string" ? props.src : ""
    if (!src) {
      return React.createElement(
        "div",
        {
          className:
            "sw-image sw-image-empty rounded-[var(--radius)] border border-dashed border-border bg-muted/50 px-4 py-6 text-center text-sm italic text-muted-foreground",
        },
        "Image unavailable"
      )
    }

    return React.createElement("img", {
      className: "sw-image w-full rounded-[var(--radius)] shadow-[var(--shadow-card)]",
      src,
      alt: String(props.alt || ""),
      loading: "lazy",
    })
  }
}

function clampLevel(level) {
  const n = Number(level)
  if (!Number.isFinite(n)) return 2
  return Math.min(6, Math.max(1, Math.trunc(n)))
}

// --- legacy socialware set (preserve sw-* contract classes/roots) ------------

function Container(React) {
  return function ContainerNode({props, children, registry}) {
    const layout = props.layout === "grid" ? "grid" : "stack"
    // Tailwind styling lives ALONGSIDE the sw-* contract classes. Grid →
    // responsive two-up; stack → vertical rhythm.
    const layoutClasses =
      layout === "grid"
        ? "grid grid-cols-1 gap-4 sm:grid-cols-2"
        : "flex flex-col gap-4"

    return React.createElement(
      "section",
      {
        className: `sw-container sw-container-${layout} rounded-[var(--radius)] bg-card shadow-[var(--shadow-card)]`,
      },
      React.createElement(
        "div",
        {className: `p-4 text-card-foreground ${layoutClasses}`},
        children.map((child, index) =>
          renderJsonNode(React, {...child, key: child.key ?? index}, registry)
        )
      )
    )
  }
}

function TextNode(React) {
  return function TextJsonNode({props}) {
    return React.createElement(
      "p",
      {className: "sw-text text-sm leading-relaxed text-foreground/80"},
      String(props.text || "")
    )
  }
}

function TableNode(React) {
  return function TableJsonNode({props}) {
    const columns = Array.isArray(props.columns) ? props.columns : []
    const rows = Array.isArray(props.rows) ? props.rows : []

    // Keep `table` as the ROOT element — the renderer-contract test asserts
    // `tableNode.type === "table"`.
    return React.createElement(
      "table",
      {
        className:
          "sw-table w-full overflow-hidden rounded-[var(--radius)] border border-border text-sm",
      },
      React.createElement(
        "thead",
        {},
        React.createElement(
          "tr",
          {className: "border-b border-border bg-muted/60"},
          columns.map((column) =>
            React.createElement(
              "th",
              {key: column, className: "px-3 py-2 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground"},
              String(column)
            )
          )
        )
      ),
      React.createElement(
        "tbody",
        {},
        rows.map((row, rowIndex) =>
          React.createElement(
            "tr",
            {key: rowIndex, className: "border-b border-border odd:bg-muted/30 hover:bg-muted/60"},
            columns.map((column) =>
              React.createElement(
                "td",
                {key: column, className: "px-3 py-2 text-sm text-foreground"},
                String(row[column] ?? "")
              )
            )
          )
        )
      )
    )
  }
}

function CodeNode(React, Sandpack) {
  return function CodeJsonNode({props}) {
    const source = String(props.source || "")
    const language = String(props.language || "jsx")

    // Keep Sandpack as the ROOT element — the renderer-contract test asserts
    // `codeNode.type === Sandpack`. Visual framing is supplied via Sandpack's
    // own `className` (a bordered, rounded card) rather than a wrapper div.
    return React.createElement(Sandpack, {
      className: "sw-code overflow-hidden rounded-[var(--radius)] border border-border shadow-[var(--shadow-card)]",
      template: language === "html" ? "static" : "react",
      files: codeFiles(language, source),
      options: {
        showNavigator: false,
        showLineNumbers: true,
        showTabs: false,
      },
    })
  }
}

function UnknownNode(React) {
  return function UnknownJsonNode({nodeType}) {
    return React.createElement(
      "div",
      {
        className:
          "sw-unknown-node rounded-[var(--radius)] border border-dashed border-border bg-muted/50 px-4 py-3 text-sm italic text-muted-foreground",
        "data-node-type": nodeType,
      },
      `Unsupported node type: ${nodeType}`
    )
  }
}

function codeFiles(language, source) {
  if (language === "html") {
    return {"/index.html": source}
  }

  return {
    "/App.js": source,
  }
}
