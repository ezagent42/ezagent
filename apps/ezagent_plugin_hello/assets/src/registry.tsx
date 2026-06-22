import {defineRegistry} from "@json-render/react"
import {catalog} from "./catalog"

// The component implementations for the hello catalog. Inline styles (not
// Tailwind/daisyUI classes) so the island renders self-contained inside the
// world LiveView operator shell — which does NOT ship the customer SPA's
// daisyUI build. Each renderer receives `{props, children}` from @json-render.
const clampLevel = (v: unknown): number => {
  const n = Number(v)
  return Number.isFinite(n) ? Math.min(6, Math.max(1, Math.trunc(n))) : 2
}

const card: React.CSSProperties = {
  border: "1px solid #e5e7eb",
  borderRadius: 12,
  padding: 16,
  display: "flex",
  flexDirection: "column",
  gap: 8,
  background: "#fff",
}

const btn: React.CSSProperties = {
  display: "inline-block",
  width: "fit-content",
  padding: "8px 16px",
  borderRadius: 8,
  background: "#4f46e5",
  color: "#fff",
  fontSize: 14,
  fontWeight: 500,
  textDecoration: "none",
  border: "none",
  cursor: "pointer",
}

export const {registry} = defineRegistry(catalog, {
  components: {
    page: ({props, children}) => (
      <main style={{display: "flex", flexDirection: "column", gap: 24, maxWidth: 768, margin: "0 auto"}}>
        {props.title ? <h1 style={{fontSize: 24, fontWeight: 600, letterSpacing: "-0.02em"}}>{String(props.title)}</h1> : null}
        {children}
      </main>
    ),
    section: ({props, children}) => (
      <section
        style={
          props.layout === "grid"
            ? {display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: 16}
            : {display: "flex", flexDirection: "column", gap: 16}
        }
      >
        {children}
      </section>
    ),
    card: ({props, children}) => (
      <div style={card}>
        {props.title ? <h2 style={{fontSize: 16, fontWeight: 600}}>{String(props.title)}</h2> : null}
        {children}
      </div>
    ),
    heading: ({props}) => {
      const lvl = clampLevel(props.level)
      const Tag = `h${lvl}` as keyof JSX.IntrinsicElements
      const sizes: Record<number, number> = {1: 24, 2: 20, 3: 18, 4: 16, 5: 14, 6: 13}
      return <Tag style={{fontSize: sizes[lvl], fontWeight: 600, letterSpacing: "-0.01em"}}>{String(props.text ?? "")}</Tag>
    },
    text: ({props}) => <p style={{fontSize: 14, lineHeight: 1.6, color: "#374151", margin: 0}}>{String(props.text ?? "")}</p>,
    button: ({props}) => {
      const label = String(props.label ?? "")
      return props.href ? (
        <a style={btn} href={String(props.href)}>{label}</a>
      ) : (
        <button type="button" style={btn}>{label}</button>
      )
    },
    image: ({props}) =>
      props.src ? (
        <img style={{width: "100%", borderRadius: 12, border: "1px solid #e5e7eb"}} src={String(props.src)} alt={String(props.alt ?? "")} loading="lazy" />
      ) : (
        <div style={{border: "1px dashed #d1d5db", borderRadius: 12, padding: 24, textAlign: "center", color: "#9ca3af", fontStyle: "italic"}}>
          Image unavailable
        </div>
      ),
  },
})
