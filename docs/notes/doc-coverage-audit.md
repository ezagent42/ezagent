# Documentation coverage audit (2026-06-13)

Audit of `@moduledoc` / `@doc` coverage and **quality** across `apps/*/lib`,
plus the calibration baseline for the new `mix ezagent.doc.scan` enforcement
gate (`apps/ezagent_core/test/architecture/doc_coverage_test.exs`).

> Scope: AUDIT + enforcement gate only. This note is the input for a later
> comment-improvement campaign (ratcheting the baseline DOWN); it does NOT
> itself fill in missing docs.

## Method + exclusions

Measured with an AST walk (`Code.string_to_quoted` → `Macro.prewalk` over each
`defmodule`), not a line/regex heuristic, so nested modules, multi-clause defs,
and `@doc`/`@impl` attribute association are exact. The same AST logic backs the
enforcement scanner (`Mix.Tasks.Ezagent.Doc.Scan`).

**Files measured:** `apps/*/lib/**/*.ex`.

**Excluded:**
- `*/test/**` and `*_test.ex` (test files + `test/support`).
- The scanner module itself (`ezagent.doc.scan.ex`).

**NOT excluded, but counted in a separate bucket:** `lib/mix/tasks/**` — Mix
tasks carry `@shortdoc` + `@moduledoc` by Mix convention, so they are well
covered and not noisy here (excluding them barely moves the module number:
1.2% → 1.3% undocumented). The gate exempts the Mix-task `run/1` callback (it is
`@impl Mix.Task`) automatically via the `@impl` rule.

**Public function counting rule:** a public function is one distinct
`{name, arity}` per module declared with `def` (not `defp`). `@impl` callbacks
(framework contract obligations — GenServer/LiveView/Behaviour/Lifecycle/
Mix.Task etc.) are tracked separately and excluded from the "should have `@doc`"
denominator, mirroring how the existing arch gate exempts behaviour callbacks.
Macro-generated functions are not in the source AST so they are naturally out of
scope.

## Part A — Coverage (quantitative)

Measured 2026-06-13 on `origin/main` (`3f8d28b3`):

### Modules

| Metric | Count | % |
|---|---:|---:|
| Total modules (in scope) | 499 | — |
| With a real `@moduledoc` | 453 | 90.8% |
| With `@moduledoc false` | 40 | 8.0% |
| With **any** `@moduledoc` (real or `false`) | 493 | **98.8%** |
| **Without any `@moduledoc`** (offenders) | 6 | 1.2% |

Excluding `lib/mix/tasks/**`: 450 modules, 6 without `@moduledoc` (1.3%).

### Public functions

| Metric | Count | % |
|---|---:|---:|
| Total public `def` (unique name/arity per module) | 2084 | — |
| ...of which `@impl` callbacks | 533 | — |
| Non-`@impl` public `def` (the gate denominator) | 1551 | — |
| With `@doc` (real or `false`) | 1143 | 54.8% of all public |
| ...real `@doc` | 1005 | — |
| ...`@doc false` | 138 | — |
| **Undocumented non-`@impl` public `def`** (offenders) | 428 | — |
| `@doc` coverage of non-`@impl` public `def` | — | **72.4%** |

### The 6 undocumented modules (module offenders)

All six are framework/boilerplate modules where a one-liner `@moduledoc` or an
explicit `@moduledoc false` is the right fix (none warrant prose):

- `apps/ezagent_core/lib/ezagent_core/repo.ex` :: `EzagentCore.Repo` (`use Ecto.Repo`)
- `apps/ezagent_web/lib/ezagent_web/endpoint.ex` :: `EzagentWeb.Endpoint` (`use Phoenix.Endpoint`)
- `apps/ezagent_web/lib/ezagent_web/router.ex` :: `EzagentWeb.Router` (`use ..., :router`)
- `apps/ezagent_domain_instance_message/lib/ezagent/socialware/customer_outbox.ex` :: `Ezagent.Socialware.CustomerOutbox` (Ecto schema)
- `apps/ezagent_domain_instance_message/lib/ezagent/socialware/settlement_message.ex` :: `Ezagent.Socialware.SettlementMessage` (Ecto schema)
- `apps/ezagent_domain_instance_message/lib/ezagent/socialware/settlement_record.ex` :: `Ezagent.Socialware.SettlementRecord` (Ecto schema)

## Part B — Quality (qualitative WHY-vs-restates)

The bar Allen cares about: a doc must capture **decisions, rationale,
invariants, call/modify gotchas, and provenance (PR / Allen-date)** — not
paraphrase the body. Sample of 15 representative modules across core / domain /
plugin:

| Module | Tier | Verdict | Note |
|---|---|---|---|
| `Ezagent.Invocation` | core | **good** | 12-step flow, phase provenance, §-refs, reply-table rationale |
| `Ezagent.Capability` | core | **good** | 5-field match semantics, `@enforce_keys` WHY, Decision #81 revoke chokepoint |
| `Ezagent.Kind.Runtime` | core | **good** | effect-bucket ORDER + per-bucket rationale, SPEC refs |
| `Ezagent.Behavior` | core | **good** | Phase-3 deletion note, "Why no macros" Decision #84, post-init hook WHY |
| `Ezagent.SpawnRegistry` | core | **good** | plugin-isolation north-star, idempotency contract, `spawn` vs `spawn_detailed` gotcha |
| `Ezagent.Entity.Agent` | domain | **good** | two spawn paths, Decision #61, V1-prevention Allen-2026-05-21, isolation memory ref |
| `Ezagent.Identity` | domain | **good** | spec §-ref, PR #142 rename provenance, self-grant cap rationale |
| `Ezagent.ExternalMirror` | domain | **good** | bind/unbind 3-check flow, codex review rounds, defence-in-depth WHY |
| `EzagentPluginLiveview.AdminLive` | plugin | **good** | Phase-8b redesign, owned-state inventory, what MOVED out + why |
| `Ezagent.Behavior.Echo` | plugin | **good** | Phase-B Lifecycle migration provenance, transients rationale |
| `EzagentWeb.Router` | web | **thin** | no `@moduledoc`, but inline `Plugs.Locale` ordering comment carries real WHY |
| `Ezagent.Socialware.CustomerOutbox` | domain | **thin** | no `@moduledoc`; field-level inline comments carry some WHY (P2.5b version note) |
| `EzagentCore.Repo` | core | **restates/boilerplate** | no doc; pure `use Ecto.Repo` (legitimately needs only a 1-liner / `false`) |
| `EzagentWeb.Endpoint` | web | **restates/boilerplate** | no doc; standard Phoenix endpoint |
| `Ezagent.Socialware.SettlementRecord` | domain | **restates/boilerplate** | no doc; pure Ecto schema, no rationale captured |

**Tally (15-module sample):** good 10 · thin 2 · restates/boilerplate 3.

**Function-level spot check:** multi-line `@doc` blocks generally carry WHY
(e.g. `Identity.list_caps_for/1` documents the boot-window fallback). One-line
`@doc`s split: some are precise contracts (`Idempotency.has?/1` → "O(1)"
complexity note), but several **restate the name**
(`FacadeRegistry.ops_for/1` → "List facade ops for one kind",
`FacadeRegistry.kinds/0` → "List all kind_types...") — these are the prime
targets of the later restates-code WARN heuristic and the improvement campaign.

**Takeaway:** module *coverage* is excellent (98.8% have some moduledoc); the
real debt is (a) 428 undocumented public functions (72.4% function coverage)
and (b) a long tail of thin one-line docs that restate the signature. The
quality of the *substantive* core/domain moduledocs is high and is the model to
hold the rest to.

## Enforcement gate + baseline calibration

See `apps/ezagent_core/lib/mix/tasks/ezagent.doc.scan.ex` +
`apps/ezagent_core/test/architecture/doc_coverage_test.exs`. Two ratchet
counters (mirroring the arch-gate `assert_at_or_below` pattern), with caps
captured in `arch_baseline_manifest.exs`:

- `undocumented_public_modules: 6` — public modules with no `@moduledoc`
  (real or `false`).
- `undocumented_public_defs: 535` — non-`@impl` public API forms
  (`def` + `defmacro` + `defdelegate` + `defguard`, plus statically-named
  public defs emitted from `quote` blocks, minus the `child_spec`/`start_link`
  boilerplate allowlist) with no `@doc` (real or `false`). Only `@impl true` /
  `@impl SomeBehaviour` exempt — `@impl false` does not.

> **Denominator covers all public API forms (codex 2026-06-14).** An early
> version of the scanner counted only raw `def`, which let public API exposed
> via `defdelegate` (e.g. the `EzagentDomainInstanceMessage` facade) and
> `defmacro` / `defguard` (the `Ezagent.Kind` / `Ezagent.Behavior` DSL) slip
> past the ratchet. The scanner now counts those forms too; this lifted the
> calibrated baseline from 461 (def-only) to 513 — the 52 previously-invisible
> undocumented delegates/macros/guards. `doc_coverage_test.exs` has a fixture
> regression test (`scan_source/1`) proving an undocumented delegate/macro/guard
> now fails the gate.

> **Denominator recurses into compile-time containers (codex 2026-06-14).** The
> scanner also descends into top-level `if` / `unless` / `case` / `cond` bodies,
> so an environment- or version-gated public def (e.g. `if Mix.env() == :prod do
> def … end`) is counted rather than escaping through the catch-all branch.
> `quote` blocks are deliberately NOT recursed (macro-generated, not a
> hand-written public def). The codebase currently has zero such conditional
> public defs (the count was unchanged at 513), so this is forward-looking
> robustness; fixtures in `doc_coverage_test.exs` prove the recursion.

> **Macro-generated (quoted) public API — counted (codex 2026-06-14).** A
> whole-module `Macro.prewalk` finds every `quote` block (they live inside
> def/defmacro bodies) and counts the STATICALLY-named public defs they emit
> (e.g. the `kinds/0`/`behaviors/0` defaults a `__using__/1` injects) — once, at
> the source, not per call-site. This closed a real hole: under the earlier
> "skip quote, the generator macro is counted" policy, adding a new quoted public
> def under an *already-documented* generator never moved the counter (+22 defs
> were invisible). DYNAMICALLY-named heads (`def unquote(n)`) yield no static
> `{name, arity}` and are skipped (the counted generator macro is their
> backstop). Fixtures in `doc_coverage_test.exs` prove both.

> **`@impl false` does not exempt (codex 2026-06-14).** Only `@impl true` /
> `@impl SomeBehaviour` mark a behaviour-callback obligation; `@impl false`
> explicitly means "not a callback", so a public def preceded by it is still
> counted (regression fixture proves it).

> The def-only `461` from the canonical scanner was slightly higher than the `428` in the
> §A function table above. The difference is attribute-adjacency strictness: the
> gate scanner only lets a pending `@doc`/`@impl` carry across *module
> attributes* (`@spec`/`@dialyzer`/…) to the next `def`, and clears it across a
> non-attribute form (a macro call / `import`) so a stray `@impl` can't leak
> onto an unrelated later def. The exploratory §A script was looser. The gate's
> number is the authoritative baseline.

The gate is GREEN at these caps on `origin/main` (a ratchet, not a day-one red
build). The `restates-code` heuristic is WARN-only (printed by
`mix ezagent.doc.scan`, never fails the suite).

### How to ratchet DOWN (the campaign)

1. Add a `@moduledoc` (or justified `@moduledoc false`) / `@doc` to one or more
   offenders.
2. Re-run `mix ezagent.doc.scan` to read the new measured counts.
3. Lower the cap(s) in `arch_baseline_manifest.exs` to the new measured value.
   Because the new count is *lower* than the previous cap, the
   `# arch-cap-bump:` annotation is NOT required (that annotation is only for
   raises). A raise (regression — new undocumented module/def) fails the gate
   and, if intentional, must carry `# arch-cap-bump: <reason>` like every other
   arch counter.

The end state of the campaign is `undocumented_public_modules: 0` and a
substantially lower `undocumented_public_defs` (the remaining justified ones
carry `@doc false`, which counts as documented).
