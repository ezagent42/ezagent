# ConfigGovernance unification (#158) + Manifest YAML serialization (Q2b) — Design

**Status:** rev1 — for codex adversarial review, then codex implementation handoff.
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
- Call sites (3, all non-test): the two governance modules + itself.
- Gate: `git grep -l "Socialware.ConfigChangeStore"` over `apps/` returns empty
  (tests updated too); full suite green.

### A2. Extract the genuinely duplicated workflow glue

New thin module **`Ezagent.ConfigGovernance`** (identity app,
`apps/ezagent_domain_identity/lib/ezagent/config_governance.ex`) — subject-agnostic
helpers ONLY where both paths do the same thing today:

- `fetch_cr(cr_id)` — fetch + `:cr_not_found` normalization
- `assert_status(cr, expected)` — open/published status guards
- `assert_workspace(cr, ctx)` — CR-workspace vs caller-workspace assertion

Explicitly **NOT** extracted (they are subject policy, and they differ):
agent CE-1 self-binding + self-CR assertion + sandbox materialization + repoint;
socialware manage-cap/admin/public-scope moderation + retract/restore.

### A3. Per-subject policy naming convergence

- **`Ezagent.ConfigGovernance.Agent`** (identity app): the agent-subject policy core
  extracted from the ActionSet — self-CR assertions, CE-1 binding checks, repoint,
  sandbox-effects assembly. **`Ezagent.ActionSet.ConfigGovernance` keeps its module
  name and every dispatched action name/cap unchanged** (it is a registered Kind
  ActionSet; renaming dispatch surface is out of scope and risky) — its `handle_*`
  bodies become thin delegations into `ConfigGovernance.Agent` + `ConfigGovernance`
  helpers.
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
- `render(%Definition{}) :: {:ok, binary}` — canonical YAML out (stable key order,
  omit empty/default fields), built on `Definition` → json-safe map (definition.ex:135
  `json_safe/1` path) → YAML encode.
- Round-trip property test: `render |> parse |> ManifestResolver.resolve |>
  Definition.new` ≡ the original resolved Definition (modulo defaulted fields).

### B3. Governed import boundary

`ManifestYaml.import(binary_or_path, ctx)` = `parse` → `ManifestResolver.resolve`
(uses/name-ref fail-closed checks) → **`ConfigGovernance.Socialware.publish_or_upgrade/2`**.
Same governed, idempotent, cap-enforced boundary the hello boot-publish dogfood uses
(`socialware/demo/hello.ex`). **No new authority is created**: import with an
unauthorized ctx fails exactly like a form save would.

Export: `ManifestYaml.export(name, workspace_uri) :: {:ok, yaml}` — registry fetch →
`render`.

### B4. Operator surface

`mix ezagent.socialware.import <file>` and `mix ezagent.socialware.export <name>`,
following the existing `mix ezagent.*` operator-task conventions (operator actions go
through mix tasks on the node, never raw RPC). Boot-time deploy-seed directory scan is
a **follow-up slice**, not this PR.

### B5. Dogfood = the acceptance gate

Author `apps/ezagent_domain_session/priv/socialware/autoservice/manifest.yaml` in the
canonical format, covering the subset the Definition actually executes today: `name,
version, title, description, uses, roles (agent slots: recipe+flavor), routing_rules,
views, visibility_policy`. Then the invariant e2e test:

```
import(manifest.yaml) → publish (governed) → DefinitionRegistry.list/1 shows it
  → install into a session → installed session materializes the declared agents
  → routing delivers a message per routing_rules (use-step assertion)
```

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
- Import authority: strictly inherited from `publish_or_upgrade` (manage-cap /
  admin / public-scope moderation all apply unchanged). The mix task runs as node
  operator — same trust level as existing `mix ezagent.*` tasks.
- PR-A moves no authorization logic across trust boundaries; auth code is extracted
  verbatim per subject (A3), shared helpers are assertion-only.

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
