# ConfigGovernance unification (#158) + Manifest YAML serialization (Q2b) — Design

**Status:** rev5 — rev1 review: UNSOUND (8 findings, fixed as `[R‑n]`); rev2 re-review:
UNSOUND (2 new BLOCKERs, fixed as `[R2‑n]`); rev3 review: 1 MAJOR + 2 MINOR (fixed as
`[R3‑n]`); rev4 delta review: **SOUND** (zero findings, 3 builder-verify notes).
rev5 (post-SOUND scope decision, Allen 2026-07-06): two former deferrals folded in —
`.Socialware` alias rename → PR-A, boot deploy-seed scan (local priv/ lane) → PR-B —
and the substrate rename promoted from open-ended follow-up to a triggered **PR-C**.
Architecture unchanged from the SOUND rev4; the folds reuse already-reviewed patterns
(the PR-A mechanical-rename sweep; the hello boot-publish chain generalized).
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
- `[R‑8]` **Not in PR-A — but a committed PR-C, not an open-ended defer:** the deeper
  substrate modules the Store aliases — `Ezagent.Socialware.{ConfigChangeItem,
  ConfigChangeRequest, ConfigObject, ConfigStore}` (config_change_store.ex:36) — carry
  the same layer/scope misnaming and get their honest names in **PR-C** (§7.4: target
  names + explicit trigger). They stay out of PR-A only because a repo-wide rename of
  the T1/T2 config land must not collide with the teammate branches currently open on
  the same files; PR-C runs the same mechanical sweep once those land.
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
- **`Ezagent.Socialware.ConfigGovernance.Socialware` → `Ezagent.ConfigGovernance.Socialware`**
  (rev5, was deferred — Allen 2026-07-06: solvable now, fold in). Same public API
  (`open_cr/stage_definition/publish_cr/publish_or_upgrade/retract/restore/reject_cr`),
  internals use the shared helpers + renamed Store. This is the SAME mechanical
  global-rename pass PR-A already performs for the Store — one more symbol in the
  same sweep, plain module (no dispatch surface), call sites are seeds/world/tests.

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

`[R2‑2]` **bases/shape ARE YAML-authorable — as fully-qualified module-name
strings** (e.g. `shape: ["Ezagent.ActionSet.Turn", ...]` — `[R3‑3]` note the real
module family is `Ezagent.ActionSet.*`, e.g. behavior/turn.ex:1; the dogfood
manifest must name the actual modules, verified by the parser itself). Rev2 tried to exclude
them, which is inconsistent with reality: no `uses`→shape expansion exists
(`ManifestResolver.resolve/1` only validates `uses` and resolves `views`,
manifest_resolver.ex:15), runtime installation derives its behavior set from
`views ++ shape ++ bases` (`Definition.behaviors/1`, definition.ex:117 →
`Installation.behavior_set_for_template/2`, installation.ex:58), and the editor's
complete-validation rejects empty bases/shape (definition_editor.ex:284) — so a
functional dogfood manifest REQUIRES them. Mechanism:

- `parse/1` maps each string via `String.to_existing_atom("Elixir." <> name)`
  rescued to `{:error, {:unknown_module, name}}` — **existing atoms only** (no atom
  minting; an unloaded/unknown module fails closed), followed by
  `Code.ensure_loaded?/1`. Conformance's `bases_shape_load` check then re-verifies.
- `render/1` emits the symmetric module-name strings (`inspect(mod)` form without
  the `Elixir.` prefix). Round-trip holds for bases/shape.
- **One-way-door note:** the §3 name-ref door (authors pick registered pieces, not
  modules) is about the RUNTIME authoring surface. This YAML channel is the
  operator/repo-authored config-repo lane (import is operator-gated, B4), where
  module refs are the same trust class as the code seeds they replace. Upgrading
  bases/shape to registered contribution ids remains follow-up §7.5 and would slot
  into `parse/1` transparently.

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
  never silently emit a module string for `views`. (`bases`/`shape` are the one
  deliberate exception: they render/parse as module-name strings by design — see B1
  `[R2‑2]` — because no name registry exists for them yet.)
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
3. `[R‑1][R2‑1]` **`Conformance.check_candidate(definition, ctx.workspace_uri)`** —
   a NEW candidate-aware entry point PR-B must add to `Conformance`
   (conformance.ex:41), because the existing `check/2` cannot pass for a
   *not-yet-published* definition: `check_install_resolves/2` does
   `DefinitionRegistry.lookup(ws, name)` (conformance.ex:247) and
   `check_template_installable` resolves through the registry-backed install path
   (conformance.ex:254 → installation.ex:58) — a valid FIRST import would always be
   rejected. Mechanism: `check_candidate/2` runs the same check list with a
   candidate-aware lookup (`fn ws, ^name -> {:ok, candidate, nil};
   ws, other -> DefinitionRegistry.lookup(ws, other) end`), so cross-references to
   OTHER definitions still hit the real registry. `[R3‑1]` **This requires
   lookup-aware `Installation` variants, not just a Conformance change** —
   `check_template_installable` reaches the registry through
   `Installation.resolved_template_installs/2` and `behavior_set_for_template/2`
   (conformance.ex:254), whose private `resolve_definitions/2` hard-calls
   `DefinitionRegistry.lookup/2` for unpinned installs (installation.ex:58, :475).
   PR-B therefore adds `Installation.resolved_template_installs/3` and
   `Installation.behavior_set_for_template/3` taking `lookup_fun:` (default
   `&DefinitionRegistry.lookup/2`), threaded through `resolve_definitions/3` and the
   unpinned `resolve_install/3`; the existing arity-2 heads delegate with the
   default, so every current caller is byte-compatible. `Conformance.check_candidate/2`
   calls the arity-3 variants. `check/2` keeps its current post-publish semantics
   unchanged (it backs `mix ezagent.socialware.check`).
   `[R3‑2]` **Completeness bar = conformance, deliberately NOT the editor's
   `complete: true` check.** `publish_or_upgrade/2` itself only normalizes via
   `Definition.new/1` (socialware.ex:116→:265) — it never ran
   `DefinitionEditor.validate_definition(complete: true)` (definition_editor.ex:284)
   for ANY caller; that check is the declarative FORM's UX contract (a human can't
   save a half-filled form). Import files may be legitimately minimal (e.g. no
   `prompt_templates` when unused); what import guarantees is MATERIALIZABILITY,
   which is exactly `check_candidate/2`.
   `{:error, failures}` aborts the import — **nothing is published**. (The hello
   boot-publish skips conformance only because its manifest is code-controlled;
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

**Boot deploy-seed scan — IN SCOPE** (rev5, was deferred — Allen 2026-07-06: the
local channel doesn't need registry P1). At application boot, behind a config
flag (default on in dev/prod, off in test), scan
`priv/socialware/*/manifest.yaml` and run each through the SAME import chain
(parse → resolve → check_candidate → publish_or_upgrade) under the operator
admin ctx — exactly the hello boot-publish pattern generalized from one
hardcoded module to a directory convention. Idempotency is free
(`publish_or_upgrade` → `{:ok, :exists}` on unchanged re-boot; fail-loud on a
broken manifest crashes the boot rather than silently skipping — hello.ex:44-46
precedent). Gate: boot-twice test asserts single publish then `:exists`; a
deliberately broken manifest in the scan dir fails the boot. (The REMOTE
config-repo channel still waits on registry P1 — only the local priv/ lane
lands here.)

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

- YAML parsing: `YamlElixir` safe load only; **no atom minting from input** — field
  keys map through a known-field whitelist, and bases/shape module strings go through
  `String.to_existing_atom` (rescued to an error tuple) which cannot grow the atom
  table `[R2‑2]`; parse errors return tagged tuples, never raise into the caller.
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
either order; each is a bounded sub-step with its own gates. **PR-C** (substrate
rename, §7.4) is sequenced strictly LAST and additionally gated on the open
socialware-area teammate branches having merged (trigger named in §7.4) — codex
should confirm the trigger with the coordinator before starting it. Target branch
owned by codex; coordinator (Claude) validates gates + merges per team process.

## 7. Follow-ups registered (out of scope here)

1. Assets ingestion pipeline (`Definition.assets` → install-time materialization) —
   unlocks full autoservice/hello pure-manifest re-expression. NOT folded into
   PR-B (Allen probed 2026-07-06; holds): it is a different problem class — needs
   its own design pass (asset addressing/content-hash couples to the registry P0
   identity model, per-flavor materialization semantics), and folding it would
   double PR-B beyond a bounded codex sub-step.
2. ~~Boot deploy-seed scan~~ — **folded into PR-B** (rev5), local priv/ lane only;
   remote config-repo channel still follows registry P1.
3. ~~`.Socialware` alias rename~~ — **folded into PR-A** (rev5).
4. `[R‑8]` Substrate namespace honesty → **promoted to a concrete PR-C** (§6a):
   `Ezagent.Socialware.{ConfigChangeRequest, ConfigChangeItem}` →
   `Ezagent.ConfigGovernance.{ChangeRequest, ChangeItem}` (governance rows join
   their Store); `Ezagent.Socialware.{ConfigStore, ConfigObject}` →
   `Ezagent.Config.{Store, Object}` (subject-agnostic config land). Purely
   mechanical, no schema/table changes. **Sequenced LAST with an explicit
   trigger, not an open-ended defer**: execute after the currently-open
   socialware-area branches land (#1190 kanban, #1191 dealscout, this spec's
   PR-A/PR-B) — a repo-wide rename while four teammate branches touch the same
   land would tax every one of them with conflicts; the trigger is team traffic,
   not difficulty. Announce + team-rebase note on merge day.
5. Name-ref extension for `bases`/`shape` (registered contribution ids → modules),
   making shape-bearing socialwares YAML-authorable.
