# ConfigGovernance unification (#158) + Manifest YAML serialization (Q2b) — Design

**Status:** rev2 — rev1 codex adversarial review returned UNSOUND (2 BLOCKER / 4 MAJOR /
2 MINOR); all eight findings addressed below (marked `[R‑n]`). For re-review, then
codex implementation handoff.
**Lineage:** `2026-07-03-socialware-manifest-design.md` (on main) — this spec executes its
two remaining engineering items: the #158 governance refactor and open question Q2.
Decisions locked by Allen 2026-07-06: **Q2 = (b)** YAML as interchange format only,
**Q3 = (a)** `uses` stays whole-plugin granularity.

---

## 1. X problem

Two remaining gaps from the manifest design, one PR each:

**(A) #158 — the CR governance layering is dishonest.** The genuinely shared CR
substrate already exists — `Ezagent.Socialware.ConfigChangeStore`
(`apps/ezagent_domain_identity/lib/ezagent/socialware/config_change_store.ex`) owns the
CR lifecycle (`open → published | rejected | rolled_back`) as pure functions and is
called by BOTH subject paths. But:

- It is named `Ezagent.Socialware.*` while living in the **identity** app and serving
  **agent-subject** CRs too. The name is a lie about both its layer and its scope.
- The two governance modules around it duplicate workflow glue (fetch-CR + status
  assertion + workspace assertion + authorization pipeline) in parallel:
  - agent path: `Ezagent.ActionSet.ConfigGovernance`
    (`apps/ezagent_domain_identity/lib/ezagent/behavior/config_governance.ex`, 365 loc)
  - socialware path: `Ezagent.Socialware.ConfigGovernance.Socialware`
    (`apps/ezagent_domain_session/lib/ezagent/socialware/config_governance/socialware.ex`, 281 loc)
- A future third subject kind would fork a third copy of the glue.

**(B) Q2 — the manifest has no file serialization.** Authoring today writes the
ConfigObject directly (world form → `DefinitionEditor`, orchestrator tools, code seeds).
The registry/distribution plan (platform-as-registry + config-repo + deploy-seed,
`2026-07-04-socialware-registry-and-distribution-plan.md`) needs a **file carrier**: a
socialware you can put in a git repo, review, version, and seed across environments.
Meanwhile `apps/ezagent_domain_session/priv/socialware/autoservice/package.yaml` is a
dead legacy file — zero code parses it — in a pre-manifest format that contradicts the
current model (e.g. its `roles.*.requested_caps` names behavior modules; the manifest
model says caps come ONLY from the recipe).

## 2. Locked decisions (context, not up for re-review)

| decision | value | rationale |
|---|---|---|
| Q2 | **(b)** YAML = import/export interchange only | ConfigObject stays the runtime source of truth. YAML is the transport for config-repo / deploy-seed / human review. Not (c) file-as-source-of-truth — conflicts with runtime authoring. |
| Q3 | **(a)** `uses` = whole plugin IDs | Already implemented (`ManifestResolver.ensure_plugins_installed/1`, fail-closed). Per-contribution validation already happens for free: every view/recipe name-ref is individually resolved fail-closed at install. Finer `uses` would be redundant bookkeeping. |
| #158 shape | rename store + extract real duplication only | The "shared parent" mostly exists (ConfigChangeStore). No grand framework; see §3. |

## 3. Design A — PR-A: ConfigGovernance layering (behavior-preserving refactor)

### A1. Rename the shared store to its honest name

`Ezagent.Socialware.ConfigChangeStore` → **`Ezagent.ConfigGovernance.Store`**.
File moves to `apps/ezagent_domain_identity/lib/ezagent/config_governance/store.ex`
(same app — it already lives in identity; only the namespace was wrong).

- Mechanical rename; **no schema/table changes** (the module owns
  `ConfigChangeRequest`/`ConfigChangeItem` rows; Ecto table names are unaffected).
- `[R‑7]` Blast radius stated honestly: TWO non-test caller modules, but MANY call
  sites — the agent ActionSet calls
  `open/stage_item/unstage_item/preview/publish/reject/mark_rolled_back/fetch`
  (config_governance.ex:158+) and the socialware module calls
  `open/stage_item/publish/reject/preview/fetch` (socialware.ex:44+), plus the test
  suites of both. The rename is mechanical but repo-wide; do it with a global
  search-replace + compile, not by hand-editing "3 places".
- `[R‑8]` **Explicit non-goal:** the deeper substrate modules the Store aliases —
  `Ezagent.Socialware.{ConfigChangeItem, ConfigChangeRequest, ConfigObject,
  ConfigStore}` (config_change_store.ex:36) — also live in the identity app under the
  `Socialware.*` namespace and carry the same layer/scope misnaming. They are **NOT**
  renamed in this PR (blast radius spans the whole T1/T2 config land). This is a
  conscious scope decision, registered as follow-up §7.4, not an oversight: PR-A fixes
  the *workflow-store* symbol the two governance paths share; the substrate rename
  rides a future churn window.
- Gate: `git grep -l "Socialware.ConfigChangeStore"` over `apps/` returns empty
  (tests updated too); full suite green.

### A2. Extract the genuinely duplicated workflow glue

New thin module **`Ezagent.ConfigGovernance`** (identity app,
`apps/ezagent_domain_identity/lib/ezagent/config_governance.ex`) — subject-agnostic
helpers ONLY where both paths do the same thing today:

- `fetch_cr(cr_id)` — fetch + not-found normalization
- `assert_status(cr, expected)` — open/published status guards
- `assert_workspace(cr, ctx)` — CR-workspace vs caller-workspace assertion

`[R‑5]` **HARD CONSTRAINT — exact error-tuple preservation per caller.** The two
paths return DIFFERENT observable error terms today (socialware:
`{:cross_workspace_socialware_cr_denied, ...}` socialware.ex:250; agent:
`:subject_not_self`, `{:cr_status, ...}` config_governance.ex:270) and existing tests
pattern-match them. The shared helpers therefore return neutral internal tags and
**each caller maps them back to its exact current tuples** (e.g.
`assert_workspace/2 → :ok | {:error, {:workspace_mismatch, got, want}}`, which the
socialware caller rewraps as `{:cross_workspace_socialware_cr_denied, ...}`). Editing
an existing test's expected error term is a spec violation — if a helper can't
preserve a caller's tuple, don't extract that call site.

Explicitly **NOT** extracted (they are subject policy, and they differ):
agent CE-1 self-binding + self-CR assertion + sandbox materialization + repoint;
socialware manage-cap/admin/public-scope moderation + retract/restore.

### A3. Per-subject policy naming convergence

- **`Ezagent.ConfigGovernance.Agent`** (identity app): the agent-subject policy core
  extracted from the ActionSet. **`Ezagent.ActionSet.ConfigGovernance` keeps its
  module name and every dispatched action name/cap unchanged** (it is a registered
  Kind ActionSet; renaming dispatch surface is out of scope and risky) — its
  `handle_*` bodies become thin delegations into `ConfigGovernance.Agent` +
  `ConfigGovernance` helpers.
- `[R‑6]` **HARD CONSTRAINT — the ActionSet retains ALL Lifecycle-context and effect
  ownership.** Today it reads sibling slices `:sandbox`/`:identity`
  (config_governance.ex:45), publishes inside the live action ctx
  (config_governance.ex:209), and assembles sandbox-refresh effects post-publish
  (`sandbox_effects_for_items`, config_governance.ex:340). None of that moves. Only
  **pure functions** move to `ConfigGovernance.Agent`: they take plain data in
  (cr, items, uris, pre-read slice values) and return plain data out (decisions,
  computed repoint sets, error terms). Anything that touches `ctx`, sibling-slice
  reads, dispatch, or effect emission stays in the ActionSet. If a candidate function
  can't be made pure without changing call order, it does not move.
- **`Ezagent.Socialware.ConfigGovernance.Socialware`** → keeps its public API
  (`open_cr/stage_definition/publish_cr/publish_or_upgrade/retract/restore/reject_cr`
  are called by seeds, world, tests) but internally uses the shared helpers + renamed
  Store. Optional alias-module rename to `Ezagent.ConfigGovernance.Socialware` is
  **deferred** (blast radius: many call sites; zero behavioral value now).

### A4. Gates (PR-A)

1. Full existing suite green — this PR is behavior-preserving by definition; any
   assertion change in existing tests is a spec violation.
2. Grep gate: no `Socialware.ConfigChangeStore` references remain.
3. New invariance test: agent-path publish and socialware-path publish both land CR
   rows through `Ezagent.ConfigGovernance.Store` (asserts the single-substrate
   property that motivated #158).
4. `mix compile --warnings-as-errors`, `check_invariants`, arch gates.

## 4. Design B — PR-B: Manifest YAML (Q2b)

### B1. Canonical format

The YAML document **is the Definition attrs**, top-level keys = manifest fields
exactly as `Definition.new/1` + `ManifestResolver.resolve/1` accept them today
(`name, version, title, description, uses, roles, views, routing_rules,
visibility_policy, assets, prompt_templates, legends, adapters, ...`). No bespoke
schema, no legacy-format compatibility. The legacy autoservice `package.yaml` format
is **not** supported — it gets superseded (§B5).

**YAML-authorable field subset:** `bases` and `shape` are `[module()]` and are
**excluded from the YAML surface in this slice** — a config-only socialware that
needs shape modules must receive them through a `uses` plugin's registered
contributions (name-ref extension for bases/shape is follow-up §7.5). `render/1`
fails loudly on a Definition whose bases/shape are non-empty rather than emitting
un-importable module strings.

Verified enabler: both `Definition.get/3` (definition.ex:484) and
`ManifestResolver.get/3` (manifest_resolver.ex:156) already do dual atom/string key
lookup, so YAML string-keyed maps flow in natively.
**Impl constraint:** nested sections (`roles` entries, `routing_rules`,
`visibility_policy`) must be verified per-field for string-key handling; where a
nested parser is atom-only, normalize in `ManifestYaml.parse/1` via a whitelist of
known field names (never `String.to_atom` on arbitrary input).

### B2. New module `Ezagent.Socialware.ManifestYaml` (session app)

- `parse(binary) :: {:ok, attrs_map} | {:error, term}` — safe load via
  `YamlElixir.read_from_string/1` (dep `yaml_elixir ~> 2.9` already in the umbrella,
  ezagent_core/mix.exs:56 — add to session app deps). No atom creation from input.
  **Content-only: `parse/1` and `import/2` never take a filesystem path** (see B3/B4
  `[R‑3]`).
- `render(%Definition{}) :: {:ok, binary} | {:error, term}` — canonical YAML out
  (stable key order, omit empty/default fields).
- `[R‑2]` **Render emits AUTHORING refs, not module strings.** `Definition.body/1`
  (definition.ex:136) stringifies `views` as `"Elixir.Module"` names, which
  `ManifestResolver.resolve_view/1` (manifest_resolver.ex:73+) does NOT accept — it
  resolves registry **view ids** (`view_module.id()`) and action names. A naive
  body→YAML render therefore produces un-importable files. `render/1` must
  reverse-map each `views` module to its registered view id using the same
  enumeration the resolver uses (find the `view_module` whose backing behavior is the
  module; emit `Atom.to_string(view_module.id())`), and **fail loudly** with
  `{:error, {:unrenderable_view, module}}` when a module has no registered id —
  never silently emit a module string. Same principle for any other field where the
  struct form differs from the authoring form (`bases`/`shape` module lists are NOT
  YAML-authorable in this slice — see B1 field subset).
- Round-trip property test: `render |> parse |> ManifestResolver.resolve` ≡ the
  original resolved Definition (modulo defaulted fields) — the test corpus must
  include a Definition whose `views` were authored as registry ids, proving the
  reverse-map leg.

### B3. Governed import boundary

`ManifestYaml.import(yaml_binary, ctx)` — **content-only, never a path** `[R‑3]` —
is a four-stage fail-closed chain:

1. `parse/1` — YAML → attrs (B2)
2. `ManifestResolver.resolve/1` — `uses` plugin presence + view name-ref resolution
   (manifest_resolver.ex:14; note this is NOT the full validity gate)
3. `[R‑1]` **`Conformance.check(definition, ctx.workspace_uri)`**
   (conformance.ex:41) — the REAL materializability gate: recipes resolve, caps/role
   uniqueness, adapters registered, orchestrator URI parses, install resolves,
   template installable, routing receivers resolve, prompt refs valid, view caps
   ready. `{:error, failures}` aborts the import — **nothing is published**. (The
   hello boot-publish skips this only because its manifest is code-controlled;
   arbitrary imported files get no such trust.)
4. **`ConfigGovernance.Socialware.publish_or_upgrade/2`** — the same governed,
   idempotent boundary the hello boot-publish uses (`{:ok, :exists}` no-op /
   `{:ok, :upgraded}` re-promote semantics, hello.ex:37-46).

**No new authority is created**: import with an unauthorized ctx fails exactly like a
form save would; a public-visibility manifest additionally hits the public-scope
admin moderation gate (socialware.ex:197) unchanged.

Export: `ManifestYaml.export(name, workspace_uri) :: {:ok, yaml} | {:error, term}` —
registry fetch → `render`.

### B4. Operator surface `[R‑3][R‑4]`

`mix ezagent.socialware.import <file> [--workspace <ws>]` and
`mix ezagent.socialware.export <name> [--workspace <ws>]`, following the existing
`mix ezagent.*` operator-task conventions.

- **File access lives ONLY in the mix task layer**: the task does `File.read!` on the
  operator-supplied path and hands the binary to `ManifestYaml.import/2`. The library
  API never touches the filesystem, so no caller can turn import into server-side
  file probing. (Runtime artifact reads elsewhere go through the `system://` seam,
  fs_resolver.ex:151 — the mix task is an operator shell command, outside that seam
  by design, same as every existing `mix ezagent.*` task.)
- **Authority model — exactly the hello boot-publish precedent (hello.ex:134-141)**:
  `caller = Ezagent.URI.user(:system, :admin)`, `workspace =
  Ezagent.URI.workspace(:system)` unless `--workspace` overrides, ctx built by the
  same admin-ctx construction hello's `admin_ctx/2` uses (hello.ex:150). This is
  operator-on-node = admin trust, identical to existing operator tasks; public-scope
  moderation is satisfied by admin authority by construction. The task prints the
  outcome (`:published | :upgraded | :exists` or the conformance failure list) and
  exits non-zero on any error.

Boot-time deploy-seed directory scan is a **follow-up slice**, not this PR.

### B5. Dogfood = the acceptance gate

Author `apps/ezagent_domain_session/priv/socialware/autoservice/manifest.yaml` in the
canonical format, covering the subset the Definition actually executes today: `name,
version, title, description, uses, roles (agent slots: recipe+flavor), routing_rules,
views, visibility_policy`. Then the invariant e2e test:

```
import(manifest.yaml) → conformance passes → publish (governed)
  → DefinitionRegistry.list/1 shows it
  → install into a session → installed session materializes the declared agents
  → routing delivers a message per routing_rules (use-step assertion)
```

Plus the negative gate `[R‑1]`: a manifest with an unknown recipe (or unresolvable
routing receiver) must be REJECTED at the conformance stage with nothing published —
asserting the import path cannot mint broken artifacts.

This test MUST fail if any stage of the chain breaks — it is the completion gate for
the whole PR (a test that fails when the goal is unmet).

### B6. Explicit non-goals (PR-B)

- **persona/kb asset ingestion**: `Definition.assets` is parsed (definition.ex:95) but
  **consumed by nothing** at install today. The legacy `package.yaml` + seed script
  (`scripts/autoservice_tier1_seed.exs`) keep owning persona/kb wiring until an assets
  pipeline exists (follow-up). The legacy file gets a header comment pointing at
  `manifest.yaml` as the canonical manifest; it is NOT deleted in this PR.
- hello re-expression as pure manifest — optional stretch, not gated.
- boot-scan deploy-seed channel — follow-up (needs the registry P1 work).
- Any change to `uses` granularity (Q3 closed as (a)).

## 5. Security review

- YAML parsing: `YamlElixir` safe load only; no `String.to_atom` on input; parse
  errors return tagged tuples, never raise into the caller.
- `[R‑3]` The library API (`parse/1`, `import/2`, `render/1`, `export/2`) is
  **content-only — no function accepts a filesystem path**. File reads exist solely
  in the operator mix task. An attacker who reaches the import API can therefore
  submit content, not probe the server's filesystem.
- `[R‑1]` Import is fail-closed at four stages (parse → resolve → conformance →
  governed publish); a syntactically valid but semantically broken manifest cannot
  become a published artifact.
- Import authority: strictly inherited from `publish_or_upgrade` (manage-cap /
  admin / public-scope moderation all apply unchanged); the mix task's ctx is the
  hello boot-publish admin construction `[R‑4]` — operator-on-node trust, same as
  every existing `mix ezagent.*` task.
- PR-A moves no authorization logic across trust boundaries; auth code stays with
  its subject (A3 pure-function constraint), shared helpers are assertion-only with
  caller-side error-tuple mapping (A2 `[R‑5]`).

## 6. Sequencing & ownership

PR-A and PR-B are independent (different apps, different files; PR-B's only touch of
governance is calling the *public* `publish_or_upgrade`). Codex may land them in
either order; each is a bounded sub-step with its own gates. Target branch owned by
codex; coordinator (Claude) validates gates + merges per team process.

## 7. Follow-ups registered (out of scope here)

1. Assets ingestion pipeline (`Definition.assets` → install-time materialization) —
   unlocks full autoservice/hello pure-manifest re-expression.
2. Boot deploy-seed scan of `priv/socialware/*/manifest.yaml` (config-repo channel).
3. Optional `Ezagent.ConfigGovernance.Socialware` alias rename (defer until a natural
   churn window).
4. `[R‑8]` Substrate namespace honesty: `Ezagent.Socialware.{ConfigChangeItem,
   ConfigChangeRequest, ConfigObject, ConfigStore}` (identity app) carry the same
   `Socialware.*` misnaming as the Store did — rename in a dedicated churn window
   (touches the whole T1/T2 config land).
5. Name-ref extension for `bases`/`shape` (registered contribution ids → modules),
   making shape-bearing socialwares YAML-authorable.
