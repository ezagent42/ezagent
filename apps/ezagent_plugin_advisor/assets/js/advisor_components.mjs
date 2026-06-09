export const advisorNodeTypes = [
  { type: "text", label: "Narrative" },
  { type: "table", label: "Comparison Table" },
  { type: "code", label: "Executable Example" },
  { type: "advisor.summary", label: "Advisor Summary" },
];

export function AdvisorSummary({ node, renderChildren }) {
  const props = node?.props || {};
  const children = Array.isArray(node?.children) ? node.children : [];

  return {
    type: "section",
    props: {
      className: "advisor-summary",
      children: [
        {
          type: "h2",
          props: { children: props.title || "Advisor Summary" },
        },
        ...children.map((child) => renderChildren(child)),
      ],
    },
  };
}

export const advisorComponentRegistry = {
  "advisor.summary": AdvisorSummary,
};
