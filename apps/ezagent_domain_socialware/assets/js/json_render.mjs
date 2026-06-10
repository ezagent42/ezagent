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
    container: Container(React),
    text: TextNode(React),
    table: TableNode(React),
    code: CodeNode(React, Sandpack),
    __unknown: UnknownNode(React),
  }
}

function Container(React) {
  return function ContainerNode({props, children, registry}) {
    const layout = props.layout === "grid" ? "grid" : "stack"
    // Tailwind/daisyUI styling lives ALONGSIDE the sw-* contract classes
    // (kept verbatim — E2E + renderer tests rely on them). Grid → responsive
    // two-up; stack → vertical rhythm. Wrapped as a card body for padding.
    const layoutClasses =
      layout === "grid"
        ? "grid grid-cols-1 gap-4 sm:grid-cols-2"
        : "flex flex-col gap-4"

    return React.createElement(
      "section",
      {
        className: `sw-container sw-container-${layout} card bg-base-100 shadow-sm border border-base-300`,
      },
      React.createElement(
        "div",
        {className: `card-body ${layoutClasses}`},
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
      {className: "sw-text text-sm leading-relaxed text-base-content/80"},
      String(props.text || "")
    )
  }
}

function TableNode(React) {
  return function TableJsonNode({props}) {
    const columns = Array.isArray(props.columns) ? props.columns : []
    const rows = Array.isArray(props.rows) ? props.rows : []

    // Keep `table` as the ROOT element — the renderer-contract test asserts
    // `tableNode.type === "table"`. daisyUI `table table-zebra` + a bordered,
    // rounded, horizontally-scrollable frame applied directly on the table.
    return React.createElement(
      "table",
      {
        className:
          "sw-table table table-zebra w-full overflow-hidden rounded-box border border-base-300",
      },
      React.createElement(
        "thead",
        {},
        React.createElement(
          "tr",
          {className: "bg-base-200"},
          columns.map((column) =>
            React.createElement(
              "th",
              {key: column, className: "text-xs font-semibold uppercase tracking-wide text-base-content/70"},
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
            {key: rowIndex, className: "hover:bg-base-200/60"},
            columns.map((column) =>
              React.createElement(
                "td",
                {key: column, className: "text-sm"},
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
      className: "sw-code overflow-hidden rounded-box border border-base-300 shadow-sm",
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
          "sw-unknown-node rounded-box border border-dashed border-base-300 bg-base-200/50 px-4 py-3 text-sm italic text-base-content/60",
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
