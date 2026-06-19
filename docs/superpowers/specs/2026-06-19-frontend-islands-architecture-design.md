# LiveView + React/json-render island frontend architecture — design

> **Design spec.** Direction converged with Allen in a design session
> (2026-06-19). The decisions in §3 are **拍板'd, not options to re-open.**
> Implementation is **not** part of this document — this spec defines the
> layering, the island↔LV boundary, the rendering model, what is v1 vs
> deferred, and the phased/strangler adoption plan with a de-risk spike as
> Phase 1.
>
> Grounded against the current frontend (every code claim verified in-repo,
> per the project's "doc WHY must be code-verified" norm). Current-state
> facts are reconciled from two research notes:
> [`docs/notes/2026-06-19-frontend-unification-synthesis.md`](../../notes/2026-06-19-frontend-unification-synthesis.md)
> (#831) and
> [`docs/notes/2026-06-19-fanout-principal-elimination-design.md`](../../notes/2026-06-19-fanout-principal-elimination-design.md)
> (#836).
>
> **Note on the #831 synthesis:** that note is *pre-decision* research. Its
> current-state facts (what `json_render.mjs` is, the ~13.5K-LOC admin
> surface, the cookie/PAT auth gap) are reused here. Its *recommended path*
> — islands over `/api/v1` + a net-new cookie→cap auth bridge + a rebuilt
> parity test — is the alternative that this design **rejects** (§4.1). The
> converged crux is the opposite: islands talk to the LV they are mounted
> in, not to `/api/v1`.

## 1. Motivation & goal

ESR has two presentation layers that have drifted into dual maintenance:

1. **Admin / operator UI** — ~25 `*_live.ex` LiveViews (~13.5K LOC across
   the top-level dir plus `admin/`), built on the 3-layer atom architecture
   (`apps/ezagent_domain_ui` → `apps/ezagent_plugin_liveview`). Deterministic,
   server-validated, live-mutation surfaces (routing rules, cap grants,
   sessions, identities, plugins, PTY).
2. **Customer / loom surface** — a React island
   (`apps/ezagent_domain_socialware/assets/js/customer_app.js`) that renders
   agent-generated JSON page trees via an **in-house, display-only** 145-LOC
   renderer (`json_render.mjs`). Generative, chat-roundtrip UI.

The **backend is already unified.** Every mutation — PTY input, every LV
`handle_event`, and the auto-derived `POST /api/v1/:kind/:action` — converges
on `Ezagent.Invocation.dispatch/1` (CapBAC-enforced), and
`apps/ezagent_core/test/invariants/lv_cli_parity_test.exs` *enforces* that
every mutating LV event has a CLI/dispatch counterpart. There is no "two ways
to mutate" duplication to delete. **The gap is entirely client-side
rendering**: two renderers, one of which (the in-house one) is too weak to
express interactive UI.

The in-house `json_render.mjs` is `{type, props, children}` → `createElement`
(verified: code is `React.createElement(component, …)` over a static
`createBaseRegistry` of `container/text/table/code/__unknown` — **no events, no
bindings, no validation, no actions**). It is sufficient for loom (every
customer interaction becomes a chat-message POST → the agent regenerates the
whole tree), but it cannot express a server-validated admin form round-trip.

**Goal:** establish a single layered frontend architecture in which
- **LiveView is the invisible "front-of-backend"** — app shell, auth, routing,
  the persistent socket, and the dispatch path;
- **React/json-render islands are the visible "front-of-frontend"** — rendered,
  interactive UI, mounted via `phx-hook`;
- **one runtime-interpreted rendering layer** (`@json-render/*`) serves *both*
  build-time-authored admin layout JSON and runtime agent-generated JSON, over
  **one component registry**;

…adopted **incrementally (strangler)**, gated by a de-risk spike on one
mutating admin surface — **not** as a big-bang LiveView rewrite.

## 2. The layering & component model

```
┌──────────────────────────────────────────────────────────────────┐
│ LiveView = "front-of-backend" (invisible)                          │
│   • app shell / chrome (AppShell.app_shell, the 3-layer atoms)     │
│   • auth: cookie session (already authenticated)                   │
│   • routing (Phoenix router / live_session)                        │
│   • the persistent socket (LV socket — already connected)          │
│   • the DISPATCH PATH: handle_event → Ezagent.Invocation.dispatch  │
│                                                                    │
│   ┌────────────────────────────────────────────────────────────┐ │
│   │ React / json-render ISLAND = "front-of-frontend" (visible)  │ │
│   │   mounted via phx-hook on a single mount element            │ │
│   │   • rendered, interactive UI                                │ │
│   │   • ↑ pushEvent(...)   ↓ handleEvent(...)                   │ │
│   └────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

- **LV owns everything that is not pixels.** The cookie session is the
  authenticated identity; the LV socket is already connected; the router and
  shell already exist. An island never re-implements any of these.
- **Islands own everything that is pixels + interaction.** They mount inside an
  LV via `phx-hook` (the existing mechanism — `app.js` already wires
  `PtyTerminal`, `UriPicker`, `MentionAutocomplete`, etc. into the
  `LiveSocket` `hooks` map).
- **The component model is uniform across surfaces:** an island is a React tree
  rendered by `@json-render/*` against one registry. A "page" is a JSON tree;
  the registry maps node types to real components. The same `<Renderer
  spec=… registry=…/>` machinery renders an admin form and an agent-generated
  customer page.

This is the natural extension of the codebase as it already is:
`customer_app.js` already does `createRoot(root).render(<CustomerApp/>)` driven
by a JSON `snapshot`; `PtyTerminal` already does the phx-hook
`pushEvent`/`handleEvent` dance. This spec generalizes those two existing
patterns into one model.

## 3. The decisions (拍板'd — do not re-open)

These are recorded verbatim as the converged decisions. The rationale and the
rejected alternatives are in §4.

1. **Layering.** LV = the invisible front-of-backend (shell, auth, routing,
   socket, dispatch). React/json-render islands = the visible
   front-of-frontend, mounted via `phx-hook`. (§2)
2. **The island↔LV boundary is `phx-hook` `pushEvent`/`handleEvent` →
   `Invocation.dispatch` — NOT `/api/v1`.** (§4 — the crux.)
3. **Rendering = `@json-render/*`** (`vercel-labs/json-render`, Apache-2.0,
   runtime-interpreted), **one component registry**. The in-house 145-LOC
   `json_render.mjs` is display-only; `@json-render/*` supplies the missing
   event/binding/validation layer. **Two JSON sources, one renderer +
   registry** (§5): admin module/layout JSON authored at build-time;
   loom/agent-generated JSON produced at runtime + streamed.
4. **"Compile-to-page" is an optional *later* optimization, NOT in v1.** The
   data-driven authoring goal is met by **runtime-interpret everywhere**. A
   JSON→React compiler is worth it only later, for leaner output / faster first
   paint. (§6)
5. **PTY and other stateful byte-stream widgets stay bespoke islands** — not
   json-render nodes. xterm is already a `phx-hook`; it fits the model as a
   *registered bespoke component*. (§7)
6. **No runtime Node tier.** Build-time `npm` + `esbuild` already exists
   (verified §8); React runs in the browser. **SSR is explicitly a non-goal**
   (it is the only thing that would need a runtime Node process, and ≈0 value
   for an authed real-time admin). (§8, §10)
7. **Strangler / incremental adoption.** Keep the LV admin as-is; island-ify
   surfaces where rich/generated UI helps; the customer/loom surface is where
   json-render lands first. **Phase 1 = a de-risk spike**: ONE mutating admin
   surface (routing add-rule *or* a cap grant) as a json-render island over
   phx-hook, *beside* the existing LV, to measure real cost before broader
   adoption. (§9)

## 4. The crux — the island↔LV boundary

**Decision: an island talks to the LiveView it is mounted in, via the
`phx-hook` `pushEvent`/`handleEvent` channel, and the LV's `handle_event`
dispatches through `Ezagent.Invocation.dispatch`. Islands do NOT call
`/api/v1` directly.**

```
island onClick / onSubmit
   └─ this.pushEvent("add_rule", payload)          ── phx-hook, over the LV socket
        └─ LV  handle_event("add_rule", payload, socket)
             ├─ validate args
             ├─ Ezagent.Invocation.dispatch(%Invocation{… ctx: %{caller, caps}})   ── CapBAC
             └─ {:noreply, assign(socket, errors: …)}  ── re-render path
                  └─ this.handleEvent("form_errors", …)  ── island re-renders errors
```

This is exactly the shape `PtyTerminal` already uses, verbatim from
`apps/ezagent_web/assets/js/hooks/pty_terminal.js`:

> `term.onData((data) => this.pushEvent("pty_input", {bytes: data}))` — *"the
> LV then dispatches via Ezagent.Invocation.dispatch (CapBAC + audit …)"* and
> *"NEVER write to a PubSub topic directly from the JS side. The
> `agents_pty_input_dispatch_test` asserts the audit row count matches the
> input byte count."*

Why this boundary, and not `/api/v1`-direct (the SPA style):

**(a) It dissolves the cookie→cap auth-bridge problem.** Admin browsers
authenticate via a **session cookie**, with no PAT.
`api_v1_controller.ex`'s `resolve_caller/1` reads
`Authorization: Bearer esr_pat_…` + `X-Ezagent-Entity-URI` (or falls back to
admin) — a cookie carries neither. A `/api/v1`-direct admin SPA would need a
**net-new cookie→short-lived-token bridge** that does not exist today. The LV
**already holds the authenticated session** (`current_entity_uri` /
`ctx.caps`), so an island over phx-hook inherits that identity for free. No
bridge.

**(b) It preserves server-validated form round-trips.** Island `pushEvent` →
LV `handle_event` validates → re-renders errors back to the island via
`handleEvent`/assigns. The validation lives once, server-side, on the
authoritative state — the SPA path would re-implement validation client-side
(or round-trip every keystroke to `/api/v1`, losing the LV's diff/assign
ergonomics).

**(c) It keeps `lv_cli_parity` intact.** All mutations still converge on
`Invocation.dispatch`, reached through an LV `handle_event` clause. The
existing `lv_cli_parity_test.exs` — which *walks every LV `handle_event`
clause* and demands a `mix ezagent` counterpart — **continues to cover island
mutations unchanged**, because an island mutation IS an LV `handle_event`.
A `/api/v1`-direct path would move mutations off the `handle_event` surface the
test enumerates, forcing a **rebuilt** API+frontend parity test on a new
substrate.

### 4.1 Rejected alternative — islands over `/api/v1` (SPA style)

Rejected for admin. It requires (i) the net-new cookie→cap auth bridge of (a),
(ii) re-implementing server-validated form round-trips client-side or per
keystroke (loses (b)), and (iii) rebuilding `lv_cli_parity` as API+frontend
tests because mutations leave the `handle_event` surface (loses (c)). The #831
synthesis note listed the auth bridge as a *v1 work item*; under this design it
is the **cost of the rejected alternative**, not work we take on.

`/api/v1` is **not** deleted — it remains the canonical headless / CLI / SDK /
introspection surface (`GET /api/v1` discovery; `mix ezagent` parity). It is
simply not the path the browser admin islands use.

### 4.2 Design rule — per-action `handle_event`, not a generic passthrough

For (c) to hold, island events MUST map to **per-action LV `handle_event`
clauses** (e.g. `handle_event("add_rule", …)`), the same granularity the
parity test enumerates. **Do NOT** collapse the boundary to a single generic
`handle_event("island_dispatch", %{action, args}, …)` passthrough — a generic
handler would make `lv_cli_parity_test.exs` see one opaque event instead of one
clause per mutation, defeating the per-action parity guarantee. Each island
mutation earns its own named `handle_event` clause and its `@event_to_cli` row.

## 5. Rendering — one renderer, one registry, two JSON sources

**Rendering layer: `@json-render/*`** (`vercel-labs/json-render`, Apache-2.0,
`@json-render/*` v0.19.0). A **data-driven runtime interpreter**: a JSON tree
constrained by a catalog (Zod `defineCatalog(...)`); a `<Renderer spec=…
registry=…/>` maps nodes to real components; it supplies the
**event/action/binding/validation** layer the in-house renderer lacks, plus
component primitives, progressive streaming, and devtools. It runs entirely in
the browser over the existing JS frontend — **no Node/RSC tier beside the
BEAM** (§8).

> `@json-render/*` is a **proposed** dependency — it is **not** in `package.json`
> today (verified: deps are only `react`, `react-dom`,
> `@codesandbox/sandpack-react`). Adopting this design adds it. Its API surface
> (catalog/Renderer/streaming) is taken as a settled library-choice decision
> (it is the library Allen identified); this spec does not re-litigate it. The
> young-dependency risk is in §11.

**One registry / catalog.** A single component registry maps node types →
real components (the project's 3-layer atoms where applicable: `button`,
`card`, `badge`, `uri_picker`, table, form-field, plus bespoke registered
components like the PTY widget per §7). The same registry serves both JSON
sources.

**Two JSON sources, one renderer:**

| Source | Authored | Produced | Example |
|---|---|---|---|
| **Admin / module layout JSON** | by a developer, at **build-time** | static (shipped in the bundle) | a routing-rule form layout, a cap-grant form |
| **Loom / agent-generated JSON** | by an agent, at **runtime** | streamed to the browser | a generated customer page tree |

Both are the *same node grammar*, rendered by the *same `<Renderer>`* against
the *same registry*. The difference is provenance (build-time vs runtime) and
the interaction model (admin → `pushEvent` to its mounting LV per §4; loom →
the existing chat-message-POST regenerate loop). This is the unification: the
in-house display-only `json_render.mjs` is **replaced** by `@json-render/*` on
the customer surface (its perfect fit — agents emit catalog-constrained JSON),
and the same renderer is what an admin island uses.

## 6. v1 vs deferred

**v1 (this implementation effort — one bounded scope):**
- Add `@json-render/*` as a dependency; define the **one shared
  registry/catalog**.
- **Adopt it on the customer/loom surface** — replace the in-house 145-LOC
  display-only `json_render.mjs` with `@json-render/*` (the genuine, low-risk
  win; agents already emit catalog-shaped JSON). *Companion to Phase 1 — see
  §9 for ordering.*
- **The de-risk spike (Phase 1):** ONE mutating admin surface (routing
  add-rule *or* a cap grant) as a json-render island over `phx-hook` per §4,
  **beside** the existing LV (strangler — the LV is not deleted), to measure
  real per-surface cost. **Decision gate.**

**Deferred — explicitly, behind the spike's decision gate (NOT silently
scoped out):**
- **Compile-to-page** (a JSON→React compiler for leaner output / faster first
  paint). v1 is **runtime-interpret everywhere** — one mechanism for admin +
  agent-generated. Decision #4. Worth revisiting only as a perf optimization
  later.
- **The full admin migration** (~25 `*_live.ex` / ~13.5K LOC → json-render
  islands). Only pursued if the spike proves cheap; current research evidence
  says it will not be (auth surface, theming atoms, live-mutation tables, PTY).
- **Any `/api/v1`-direct SPA admin path** + its cookie→cap auth bridge —
  rejected for admin (§4.1); not in scope.

The v1 line is deliberately one bounded effort (one library adoption + one
spike) plus a gated future, **not** a 5-phase megaproject. The full migration
is a *separate, gate-conditioned decision*, not part of this spec's scope.

## 7. The PTY / bespoke-island boundary

**Not every island is a json-render node tree.** Stateful, byte-stream widgets
— a live terminal, and any future equivalent (e.g. a streaming log viewer, a
canvas/graph surface) — are **bespoke islands**: a hand-written React/JS
component mounted via `phx-hook`, **registered** in the same registry as a
catalog component, but **not** itself a json-render-interpreted node.

xterm/PTY is the canonical case and **already fits the model**:
`pty_terminal.js` is a `phx-hook` that pushes `pty_input`/`pty_resize` and
handles `pty_chunk`, with the `agents_pty_input_dispatch_test` audit-row
invariant. It does not need json-render's node interpretation — its content is
a raw byte stream, not a declarative tree. So the rule is:

- **Declarative / data-driven UI** (forms, tables, layouts, generated pages) →
  **json-render nodes** rendered by `<Renderer>` against the registry.
- **Stateful byte-stream / imperative widgets** (PTY, and the like) →
  **bespoke phx-hook islands**, *registered* as components in the same registry
  so a json-render layout can place one, but their internals are bespoke.

Both mount the same way (`phx-hook`) and both route mutations the same way
(`pushEvent` → LV `handle_event` → `dispatch`). The PTY hook is the existence
proof that a bespoke byte-stream island is a first-class citizen of this model.

## 8. No runtime Node tier (build-time only)

Verified in-repo:
- `apps/ezagent_web/mix.exs` aliases: `assets.setup` runs
  `cmd --cd assets npm install` + `tailwind.install` + `esbuild.install`;
  `assets.build` runs `tailwind` + `esbuild ezagent_web`; `assets.deploy`
  runs the `--minify` variants + `phx.digest`. **All build-time.**
- `config/config.exs` `:esbuild` profile bundles **both** `js/app.js` and
  `js/customer_app.js` into `priv/static/assets/js` (`--alias:@=.` — the same
  `@`-root alias json-render's docs use), with `react`/`react-dom`/`sandpack`
  resolved from `assets/node_modules`. React runs **in the browser** from the
  bundled output.
- The customer SPA is a *controller-rendered public page* (its own
  `ezagent_web_customer` Tailwind build), not a LiveView surface — yet still
  bundled at build-time, no server-side render.

So adding `@json-render/*` is a **build-time dependency addition** — `pnpm`/npm
install + esbuild bundling — with **no new runtime process**. SSR (the only
feature that would require a long-lived Node process beside the BEAM) is a
**non-goal** (§10): for an authenticated, real-time admin its value is ≈0
(no SEO, no cold first-paint-for-anonymous concern), and it would re-introduce
exactly the runtime Node tier this decision excludes.

## 9. Phased / strangler adoption plan

This is **not** a big-bang LV rewrite (§10). The LV admin stays; islands are
introduced where rich or generated UI helps.

**Track ordering (resolved — see §12 open question 1):** there are two tracks.
The customer renderer swap is the first landing of the **library** (low risk,
no mutation boundary — the renderer already exists in display-only form). The
admin spike is **Phase 1 of the architecture** (it proves the
`pushEvent`→`handle_event`→`dispatch` round-trip with server validation on the
hard case). Per the literal converged requirement, **the admin spike is the
gating Phase 1**; the customer swap is its low-risk companion (Phase 0 / runs
alongside).

- **Phase 0 (companion, low-risk): customer/loom renderer swap.** Replace
  `json_render.mjs` with `@json-render/*` on the customer surface; define the
  shared registry/catalog. Exercises the library + event machinery on the
  surface that needs the dispatch boundary *least* dangerously (customer
  interactions are the existing chat-roundtrip loop, not admin mutations).

- **Phase 1 (the de-risk spike — DECISION GATE): one mutating admin
  surface.** Build **routing add-rule** *or* a **cap grant** (both are
  live-mutation + server-validated — the representative hard case; do **not**
  pick a read-only list, which would falsely "succeed") as a json-render
  island over `phx-hook` per §4, **mounted beside the existing LV** (strangler
  — do not delete the LV). Measure the real per-surface cost (catalog
  authoring, the `pushEvent`/`handle_event`/error-re-render round-trip, theming
  atoms, the per-action parity rows) against the working LV.
  **Gate:** decide whether broader admin island-ification is worth it. Current
  evidence says it likely is not cheap — that is *why* we spike one surface
  before committing.

- **Phase 2+ (gate-conditioned, deferred — only if the spike proves cheap):**
  read-mostly admin LVs → live-mutation LVs → registered bespoke islands where
  needed → (only after every migrated surface has a tested equivalent and
  per-action parity is green) consider retiring the corresponding LV. PTY-class
  bespoke islands are already covered by §7 and need no migration. The full
  ~25-LV migration is *not* committed by this spec.

## 10. Non-goals (explicit)

- **SSR** (server-side rendering). The only feature that would need a runtime
  Node process beside the BEAM; ≈0 value for an authenticated real-time admin.
  React renders in the browser. (§8)
- **A runtime Node tier.** Build-time `npm`/`esbuild` only. (§8)
- **A big-bang LiveView rewrite.** Adoption is strangler/incremental and
  spike-gated. The LV admin stays until — and only if — each surface has a
  tested island equivalent. (§9)
- **An `/api/v1`-direct admin SPA** + its cookie→cap auth bridge. Rejected for
  admin (§4.1). `/api/v1` stays as the headless/CLI/SDK surface.
- **Re-litigating the rendering library.** `@json-render/*` is the converged
  choice; this spec does not re-evaluate it.

## 11. Risks

- **Young dependency.** `@json-render/*` is **v0.19.0 (pre-1.0)** — adopting it
  means tracking a library with likely API churn. Mitigation: it lands first on
  the customer surface (Phase 0, lower blast radius) and behind the **one
  shared registry/catalog** indirection, so an API break is absorbed at one
  seam, not scattered across every surface.
- **The auth model.** The whole no-auth-bridge argument (§4a) depends on
  islands using the LV's already-authenticated session via `phx-hook`. If a
  future surface is tempted to call `/api/v1` directly from an island "just for
  this one case," it silently re-opens the cookie→cap bridge gap. Mitigation:
  the §4.2 design rule (per-action `handle_event`) + a documented prohibition
  on island→`/api/v1` for browser-authenticated admin surfaces.
- **The parity invariant re-expression.** `lv_cli_parity` is preserved *only*
  because island mutations remain per-action LV `handle_event` clauses (§4c,
  §4.2). The risk is drift toward a generic `island_dispatch` passthrough,
  which would hollow out the test without failing it. Mitigation: state the
  per-action rule normatively (§4.2); the spike (Phase 1) must add its
  `@event_to_cli` row, proving the invariant still bites.
- **Spike under-scoping.** Picking a read-only surface for the spike would
  falsely "succeed" and not exercise the hard path (validation + mutation +
  CapBAC). Mitigation: §9 fixes the spike to a *mutating, server-validated*
  surface (routing add-rule or cap grant).

## 12. Open questions (resolved here)

1. **"Customer surface first" vs "spike as Phase 1" — contradiction?**
   *Resolved (no contradiction — two tracks).* The customer swap is the first
   landing of the **library** (low risk, no mutation boundary); the admin spike
   is Phase 1 of the **architecture** (proves the dispatch round-trip on the
   hard case). The admin spike is the *gating* Phase 1 per the literal
   requirement; the customer swap is its companion (Phase 0 / alongside). §9.
2. **Does adopting json-render require an auth bridge (as #831 says)?**
   *Resolved: no — for admin.* The #831 note assumed `/api/v1`-direct islands.
   Under the converged phx-hook→dispatch boundary, islands inherit the LV's
   authenticated session, so the bridge is unnecessary. The bridge is the cost
   of the *rejected* `/api/v1` alternative (§4.1), not a v1 item.
3. **`@json-render/*` API specifics.**
   *Resolved as out-of-scope to re-derive.* The library identity + capability
   class (catalog / Renderer / streaming) is a settled decision; exact API
   shape is an implementation-plan concern, tracked under the young-dependency
   risk (§11), not designed here.

## 13. The anon-login UX seam (reference only — designed in spec 甲)

The membership-mount model from
[`docs/notes/2026-06-19-fanout-principal-elimination-design.md`](../../notes/2026-06-19-fanout-principal-elimination-design.md)
(#836, "spec 甲") is the entity-model foundation the anon-login UX **consumes**;
it is **not** designed in this spec. Briefly, what this frontend architecture
relies on from it:

- Joining a session is **one flow for everyone**; the only difference is which
  cap set is *mounted* at join, keyed on the member's identity class
  (`:unconfirmed` → reduced view/receive-only; `:confirmed` → full
  `:send`/`:leave`/`subscribe_from`).
- **"Upgrade" = re-join at a higher identity.** An anonymous viewer who logs in
  simply **re-joins**; the full cap set is mounted. No special upgrade path.
- `confirmed` is a real entity attribute (not the legacy `anon-` name-prefix
  hack).

For this frontend spec, the consequence is only that **the anon-login UX is a
re-join, not a bespoke client flow**: a customer/loom island that lets an
anonymous viewer log in triggers a re-join (which re-mounts the confirmed cap
set server-side) rather than implementing any client-side privilege change. The
island stays a thin renderer over the LV/session it is mounted in; the identity
transition is entirely the server's membership-mount model. **Design of that
model lives in spec 甲 — do not re-derive it here.**

## 14. Self-review

- **No placeholders / TBDs** — every section is concrete; open questions are
  *resolved* (§12), not left dangling.
- **Internally consistent** — the crux (§4) is the same `phx-hook` →
  `Invocation.dispatch` boundary referenced in §2, §3, §6, §7, §9, §11; the
  auth bridge is consistently framed as the rejected alternative's cost (§4.1,
  §6, §10, §12.2), never as v1 work.
- **Scoped to ONE implementation effort** — v1 is one library adoption +
  one de-risk spike (§6, §9); the full admin migration, compile-to-page, and
  any `/api/v1` SPA path are explicitly deferred behind the gate.
- **No ambiguous requirements** — the v1/deferred line is a table + bullet
  list (§6); the spike target is fixed to a mutating, server-validated surface
  (§9); the per-action `handle_event` design rule is normative (§4.2).
- **No implementation** — this document specifies architecture and scope only;
  it writes no code.

## 15. Cross-references

- Current-state research: `docs/notes/2026-06-19-frontend-unification-synthesis.md` (#831).
- Membership-mount (spec 甲): `docs/notes/2026-06-19-fanout-principal-elimination-design.md` (#836).
- In-house renderer (display-only): `apps/ezagent_domain_socialware/assets/js/json_render.mjs`.
- React island precedent: `apps/ezagent_domain_socialware/assets/js/customer_app.js`.
- phx-hook islands (the boundary pattern): `apps/ezagent_web/assets/js/app.js`,
  `apps/ezagent_web/assets/js/hooks/pty_terminal.js`.
- Dispatch / API surface: `apps/ezagent_web/lib/ezagent_web/controllers/api_v1_controller.ex`.
- Parity invariant: `apps/ezagent_core/test/invariants/lv_cli_parity_test.exs`.
- Build pipeline: `apps/ezagent_web/mix.exs` (aliases), `config/config.exs` (`:esbuild`).
- 3-layer UI contract: `.claude/skills/ezagent-developer/references/ui-contract.md`.
- Admin LVs (~25 / ~13.5K LOC): `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/*_live.ex`.
- Library: `github.com/vercel-labs/json-render` (Apache-2.0, `@json-render/*` v0.19.0).
