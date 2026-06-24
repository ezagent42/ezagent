# Close-review finding — official site renders broken (json-render desync)

> **Owner:** zhaomato · **Origin:** consequence of #956 · **Status:** planned rework (in `plan.md`, "NEXT task for 张宁")

## Expected
The official site, generated via the hello `@json-render` pipeline, renders as a
polished shadcn/Tailwind page (reference: the demo Allen built —
http://100.64.0.27:5173/ , repo `ezagent42/json-render-demo`).

## What actually happened
The page renders **broken/empty/ugly**. Root cause (code-verified):

- #956 migrated the **backend** catalog `apps/ezagent_plugin_hello/lib/.../spec.ex`
  to **36 capitalized shadcn types** (`Stack/Card/Heading/Text/Button/...`) + the
  prompts inject that set.
- The **frontend renderer** was **never migrated**:
  `apps/ezagent_plugin_hello/assets/src/catalog.ts` + `registry.tsx` still know only
  the **old 7 lowercase** types (`page/section/card/heading/text/button/image`),
  rendered with **hand-rolled inline styles** (not real shadcn components).
- So the LLM now emits `{"type":"Stack"}` etc. that the frontend catalog doesn't
  recognise → nodes fail validation / render nothing → broken page.

Per-layer tests passed (backend), but the **product** is broken — the
"green tests, broken product" failure the demonstrable-DoD rule exists to prevent.

## Why it slipped
#956's DoD/E2E never required **rendering a generated page in the browser** and
eyeballing it, and never listed **frontend↔backend catalog parity**. The "shadcn
migration" was implicitly a cross-layer change but was scoped as backend-only.

## Disposition
Full rework is now zhaomato's next task (see `plan.md`): align the frontend
catalog/renderer to the backend shadcn set using real shadcn/Tailwind components
(reuse world's existing design tokens), design-system/token separation, per-session
theming, and a **visual E2E** (generate → render at `/socialware/customer` →
agent-browser screenshot vs the demo bar).

→ Process rules that would have caught this: **P5** (cross-layer parity + E2E
product proof), **P2** (DoD enumerated from the contract). See
`dev-together-process-improvement.md`.
