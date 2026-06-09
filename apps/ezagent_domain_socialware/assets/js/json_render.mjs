export function renderJsonNode(React, node, registry) {
  if (!node || typeof node !== "object") {
    return React.createElement("div", {"data-node-type": "invalid"}, "Unsupported node")
  }

  const type = typeof node.type === "string" ? node.type : "invalid"
  const component = registry[type] || registry.__unknown
  return React.createElement(component, {
    key: node.key || undefined,
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

    return React.createElement(
      "section",
      {className: `sw-container sw-container-${layout}`},
      children.map((child, index) => renderJsonNode(React, {...child, key: child.key || index}, registry))
    )
  }
}

function TextNode(React) {
  return function TextJsonNode({props}) {
    return React.createElement("p", {className: "sw-text"}, String(props.text || ""))
  }
}

function TableNode(React) {
  return function TableJsonNode({props}) {
    const columns = Array.isArray(props.columns) ? props.columns : []
    const rows = Array.isArray(props.rows) ? props.rows : []

    return React.createElement(
      "table",
      {className: "sw-table"},
      React.createElement(
        "thead",
        {},
        React.createElement(
          "tr",
          {},
          columns.map((column) => React.createElement("th", {key: column}, String(column)))
        )
      ),
      React.createElement(
        "tbody",
        {},
        rows.map((row, rowIndex) =>
          React.createElement(
            "tr",
            {key: rowIndex},
            columns.map((column) =>
              React.createElement("td", {key: column}, String(row[column] ?? ""))
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

    return React.createElement(Sandpack, {
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
      {className: "sw-unknown-node", "data-node-type": nodeType},
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
