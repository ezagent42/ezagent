# Architecture decision: keep the bespoke `ezagent_core` framework

**Date:** 2026-06-20 · **Status:** Decision recorded · **Decider:** Allen (林懿伦)

> Forensic/decision note. The normative architecture lives in `../../ARCHITECTURE.md`
> + `../../GLOSSARY.md` (Decision Log). This records *why* we keep the in-house
> Kind/Behavior actor framework rather than migrating to Ash or another framework.

## The question

`apps/ezagent_core` contains a **bespoke framework** — the Kind/Behavior actor
runtime — measured at **~37.6K LOC, ~30% of the codebase**. Two questions were
investigated:

1. Is our overall code quantity *healthy* for the system's feature complexity?
2. Would migrating the bespoke framework onto **Ash** (or another mature
   framework) have a worthwhile **ROI**? And specifically — is there a mature
   **actor** framework to migrate the actor model onto?

## TL;DR decision

**Keep the bespoke `ezagent_core` framework as-is, on raw OTP.** It is *correct
layering*, not bloat: mature OTP primitives (which we already build on) + a
necessary, domain-specific abstraction that no off-the-shelf library provides.

- **Ash** is a declarative *resource/data/authorization* framework, **not** an
  actor framework — it cannot replace the runtime. Greenfield-only: reasonable
  for *new* data-heavy/relational resources + their authz.
- **No mature framework replaces the actor abstraction.** The primitives
  (`GenServer`/`DynamicSupervisor`/`Registry`, +`Horde` for distribution) are
  mature and already in use. The abstraction (Kind/Behavior/slice/effects-grammar/
  inline-CapBAC/URI-addressing) is bespoke *by necessity*.
- **Commanded (CQRS/ES)** is the only paradigm-level alternative, but it is a
  *rewrite, not a migration*, and its headline benefits are largely already
  built in-house. ROI negative for the existing codebase.

## Evidence — four studies (2026-06-20)

### 1. Code composition (what each concern costs)
Production `lib/` ≈ **125K LOC** (`wc -l`; proportions reliable, absolutes ~25-40%
high vs code-only). Test code ≈ 123K (≈1:1).

| Concern | % of prod lib |
|---|---|
| Business logic | ~46% |
| Infrastructure / framework (the bespoke Kind runtime, Ecto, registries, URI) | ~29% |
| UX (LiveView 15K + web + CLI/mix-tasks 9K + JS) | ~18% |
| **Authorization (CapBAC)** | **~7%** |

**Key insight:** authorization is a **thin (~7% LOC) but pervasive cross-cutting
layer** — ~83 per-action `caps:` gates woven through the business Behaviors (the
#154 design: every action cap-gated, every cap traced to a real entity). Small
line count, broad coupling.

### 2. Size benchmark vs comparable OSS (self-measured, same `wc -l` metric)
| Project | Lang | lib LOC | test:lib |
|---|---|---:|---:|
| **ESR-ng** | Elixir | **~125K** | 1.0 |
| Plausible | Elixir | 79K | 1.67 |
| Livebook | Elixir | 68K | 0.57 |
| elixir-ls | Elixir | 66K | 0.77 |
| Ash (framework) | Elixir | 140K | — |
| Oban (library) | Elixir | 14K | — |
| CrewAI / LangGraph | Python | 110K / 82K | — |

**Verdict: healthy, arguably lean.** Subtract the ~37K bespoke framework → **~88K
"application" LOC**, squarely in the Elixir-app band (Plausible/Livebook/elixir-ls
66-79K) while covering *broader* scope. Most apps get the runtime free from
`deps/` (Phoenix/Ecto/Ash/Oban); we vendor ours in-tree, which is why a fair
app-to-app comparison is **88K, not 125K**. Test ratio 1:1 is healthy.

### 3. Ash-migration ROI — NOT worth migrating
- Ash self-describes as a *"declarative data management framework"*; a "resource"
  is a **DB row you load/modify/save**, not a live process. Ash's "actor" = the
  *acting user*, not an Erlang process.
- The bespoke 37.6K carves up as: **~9-20K Ash-hostile actor runtime** +
  **~5.5K orthogonal dev tooling (mix tasks/gates)** + **~1.7K authz
  (reimplementable, not deletable)** + only **~3-5K Ash-addressable relational
  stores** (message/rule/notif/audit/lineage/credential-grants).
- **The persistence "obvious win" is a trap:** snapshots are
  `:erlang.term_to_binary` of the slice map into one opaque `state_binary` blob
  keyed by URI (`ecto/kind_snapshot.ex`) — **Ash-hostile** (Ash wants normalized
  queryable rows, not serialized GenServer state).
- Migration = multi-quarter foundation rewrite + re-porting the 88K app (116 lib
  files reference `caps:`; 91 `required_caps`; 30 Behaviors; 5 Kinds) onto a
  *different programming model* (effect-into-actor → action-on-row), to net out
  single-digit-K LOC. **Negative ROI.** Greenfield ≠ migration.

### 4. Actor-framework migration — no mature target for the abstraction
| Framework | Replaces abstraction or just primitives? | Maturity |
|---|---|---|
| Raw OTP (GenServer/DynamicSupervisor/Registry/:gen_statem) | **primitives only — already in use** | stdlib |
| Horde | primitives only, made multi-node (drop-in for our DynamicSupervisor/Registry) | **pre-1.0**, CRDT eventual-consistency |
| **Commanded (CQRS/ES)** | **the only paradigm replacement — rewrite, not migration** | mature, post-1.0 |
| Phoenix / AshStateMachine / Broadway / GenStage / Membrane / Oban / Ra | none — transport / FSM / data-pipelines / jobs / consensus | mature |
| Akka / Orleans / Dapr / Ractor | off-BEAM — out of scope | — |

- **Primitives vs abstraction:** `kind/server.ex` *is* a GenServer over a
  DynamicSupervisor + Registry — we already sit on the mature primitives.
  "Migrating to mature primitives" is a no-op (or +Horde for distribution).
- **Commanded ROI:** the real cost is the **source-of-truth inversion** —
  today the truth is the snapshot-of-current-state (`term_to_binary` slice);
  Commanded makes the **event log the truth** (state rebuilt by replaying events).
  And the headline benefits (events + sagas) are **largely already realized
  in-house** — `event_log.ex` + `saga_runner.ex` already exist and the effects
  grammar already emits events + runs sagas. The only genuinely-new gain is
  replay-as-rebuild + read-model projections, which we don't currently need. PTY/
  streaming still needs live GenServers; CapBAC authz stays bespoke. **ROI
  negative for migration.**

## Recommendation (operational)

- **Now (brownfield):** keep the bespoke abstraction on raw OTP — correct layering.
- **Distribution:** adopt **Horde** only if/when multi-node is needed (targeted,
  low-blast-radius swap for the DynamicSupervisor/Registry; mind its pre-1.0 status).
- **New relational/data-heavy surfaces:** **Ash** is a reasonable greenfield pick
  for the *data + authz + API* layer — as a complement, never a replacement for
  the actor runtime.
- **Commanded / event-sourcing:** only if event-sourcing becomes a *product*
  requirement (it would be a new system, not a migration of this one).

## Why this matters
The 30% bespoke framework is what makes ESR-ng "look big" against stock-Phoenix
apps — but it is the **intrinsic cost of a live multi-agent actor system with
fine-grained CapBAC**, not accidental bloat. The framework market addresses
*primitives* (we already use them) and *orthogonal paradigms* (data layer /
event-sourcing), not the composable-behaviors-with-inline-authz entity runtime
we built. Keeping it is the economically and architecturally correct call.

## Cross-references
- `2026-06-19-fanout-principal-elimination-design.md` + the #154
  system-principal-elimination program (the CapBAC layer this analysis sizes).
- Normative: `../../ARCHITECTURE.md`, `../../GLOSSARY.md` Decision Log.
