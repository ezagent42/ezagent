# M3 -- `requires:` socialware-to-socialware dependencies

**Status:** rev2 -- codex-adversarially-reviewed 2026-07-07 (architecture-level), verdict SOUND
**Authority:** `docs/superpowers/specs/2026-07-06-orchestration-as-socialware-design.md` Section 6 (on main,
258bcc62c)
**Lead decision (Allen, 2026-07-07):** X confirmed -- socialware artifacts aren't self-contained because
composition dependencies live outside the artifact (in SessionTemplate config or tribal knowledge).
`uses: [plugin]` already makes code dependencies declarative and fail-closed; `requires: [socialware]`
must do the same for composition dependencies.

---

## 1. X problem -- why `requires:` is needed (code-verified)

### 1.1 Code dependencies are already declarative

The `Definition` struct already has `uses: [String.t()]` -- plugin slugs. This makes code
dependencies fail-closed: a manifest naming a plugin that isn't installed is rejected at
resolve time.

`apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:16` -- `uses: []` default
`apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:75` -- `string_list(attrs, :uses)`
`apps/ezagent_domain_session/lib/ezagent/socialware/manifest_resolver.ex:27-38` -- `uses/1` validates
`apps/ezagent_domain_session/lib/ezagent/socialware/manifest_resolver.ex:41-44` -- `ensure_plugins_installed/1`
checks every slug via `PluginRegistry.info/1` or `InstalledRegistry.lookup/1`
`apps/ezagent_domain_session/lib/ezagent/socialware/conformance.ex:136-151` -- `check_uses_plugins/1`
re-validates in Conformance

Code deps are done.

### 1.2 Composition dependencies are NOT declarative

The `hello` socialware implicitly depends on the `orchestrator` being installed in the same
session for multi-agent coordination -- it needs the orchestrator's agent tools and console
views. This knowledge lives in tribal knowledge and SessionTemplate configuration:

`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:12` -- `@default_installs ["chat"]`
-- the default template installs only `chat`; `orchestrator` is NOT a default install
`apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex:167` -- the orchestrator is
installed by `install_orchestrator_definition/3` as an explicit side-effect during session creation,
not because any socialware declares it as a dependency.

If someone creates a SessionTemplate that installs `hello` but forgets to also install
`orchestrator`, the session creates without the orchestrator tools -- hello's roles are
materialized but the operating surface is missing. This is a silent failure that the
framework cannot prevent because the dependency is invisible.

### 1.3 The install model M3 extends

`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:466-492` -- `seed_install/6`
has (session, ref) idempotency: if already installed, no-op; if removed, repoint; if none, seed.
`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:237-264` --
`repoint_template_installs/4` re-resolves every install to the current published revision.
`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:50-60` --
`resolved_template_installs/2` resolves template installs to Definition + ConfigObject tuples.

The infrastructure for install identity is already production-proven. M3 adds a dependency graph
on top of it, not beside it.

### 1.4 Existing socialwares that would benefit

The orchestrator Definition already exists (#1223, df43253b2):
```
apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex -- built-in seed
  name: "orchestrator"
  uses: ["cc"]
  roles: [{role_name: "orchestrator", fill: :agent, recipe: "orchestrator", flavor: "cc"}]
```

`hello` currently has no `requires` field. Its dependency on `orchestrator` is implicit --
the default template happens to install both. After M3, hello's Definition would declare
`requires: [orchestrator]` and the framework would guarantee the orchestrator is present
regardless of what the SessionTemplate's `installs` field says.

### 1.5 Settled decisions from the authority spec

From the orchestration ref design Section 6 (258bcc62c):

**A-1:** Single-version-per-(session,ref) invariant. One installed revision per socialware
per session, shared by all dependents (flat, npm-hoist-style).

**A-2:** Install-time auto-prefix -- role names are prefixed with the definition name
(`hello:advisor`) at materialization, making role name collisions impossible by construction.
Short names in a Definition are local references; prefixed names are cross-socialware references.

**Install-time conflict analysis (Section 3.2, shipped in M1):** The merged rule+role set of all
composed socialwares goes through the same role-DAG Conformance check (cycles, double-delivery,
dead roles). `requires` adds: role_name collision across composed definitions = REJECT.

---

## 2. Design

### M3-a: `requires` field on Definition

New field on `%Definition{}`: `requires: [String.t()]` -- socialware names, not plugin slugs.
Distinct from `uses: [String.t()]` (code/plugin deps).

```yaml
name: hello
requires: [orchestrator]    # NEW -- composition dependency
uses: [ezagent_plugin_hello] # code dependency
roles: [...]
```

An author writes `requires: [orchestrator]`. The framework recursively ensures the required
socialware is installed in the session before this one. A missing/unpublishable required
socialware causes install to fail closed -- same posture as `uses` plugin checks today.

**Validation at Definition.new/1:** `requires` is a `string_list` (same validator as `uses`,
`definition.ex:193-205`). Each entry must be a non-empty binary.

**Validation at ManifestResolver.resolve/1:** Each required socialware name must be published
in the workspace (extending the existing `manifest_resolver.ex` resolve pipeline).

**Validation at Conformance.check_candidate/2:** Cycle detection in the requires graph (M3-b)
plus version conflict checking (M3-c). Extends `conformance.ex:64-78`.

**Serialization:** `body/1` (definition.ex:129-149) includes `requires` in the JSON-safe body.
`content_hash/1` (definition.ex:169-170) includes it in the deterministic hash -- the requires
list IS part of the artifact identity.

### M3-b: Recursive install

Installing S that `requires` R triggers recursive install of R first. R's own `requires` are
resolved transitively. A requires cycle is rejected at Conformance time.

**Algorithm (in Installation.seed_install/6):**

1. Resolve the transitive closure of `requires` for S via `DefinitionRegistry.lookup/2`.
2. Topological sort: required socialwares installed first (leaves before dependents).
3. For each socialware in sorted order: call `seed_install/6` with the existing (session, ref)
   idempotency -- an already-installed required socialware is a no-op.
4. After all requirements are installed, install S itself.

**Cycle detection:** Added as a new Conformance assertion `:requires_cycle_free`. Runs during
`check_candidate/2` before publish. A cycle in the requires graph is a hard REJECT -- the
author must break the cycle.

**Behavior set:** The session's behavior set already derives from `Definition.behaviors/1`
(definition.ex:117-125) for every installed definition. Recursive install means the required
socialware's behaviors also contribute. This is automatic -- the existing
`installed_definitions/1` (installation.ex:398-415) iterates all install keys, so a newly
installed required socialware contributes its behaviors without additional plumbing.

**Role materialization:** Each installed socialware's roles materialize per ITS definition.
With A-2 auto-prefix, `hello:builder` and `orchestrator:orchestrator` coexist as distinct
role names. The existing `materialize_template_team` path already iterates installed definitions
for role materialization -- recursive install extends the set, not the mechanism.

### M3-c: Version model

**Rides the existing (session, ref) idempotency model** (installation.ex:466-492). One installed
revision per socialware per session (A-1 invariant). The install identity IS `(session, ref)` --
`requires` does not introduce per-dependent locks.

**Install-time conflict detection:** When S2's `requires` would install R, but R is already
installed at a different revision (content_hash mismatch):

1. Check whether the already-installed R satisfies S2's conformance against the installed
   revision (not the one S2 wants). Conformance of a required socialware is checked against
   the DEFINITION installed on the session, not the one being requested.
2. If the installed revision is compatible (S2's conformance passes against it): proceed --
   the session already has R, it works for S2, no conflict.
3. If incompatible: REJECT with a version-conflict error naming both dependents
   (e.g. `{:version_conflict, "orchestrator", [s1_name, s2_name]}`).

This is the npm-hoist model: one version shared. If two dependents need incompatible versions,
the operator must resolve (upgrade the dependent, or repoint R to a version that satisfies both).

**Repoint re-validation:** `repoint_template_installs/4` (installation.ex:237-264) already drops
frozen pins and re-resolves each ref to the current published revision. M3 extends repoint with
a PREFLIGHT conformance check -- validation happens BEFORE any install record is mutated:

1. Resolve the new revisions for all repointed refs (existing behavior, line 248-249).
2. BEFORE the write loop: compute the reverse dependency set -- all installed socialwares
   that transitively `require` any of the repointed refs.
3. For each reverse dependent, run `check_against_installed/3` (Section 3.2) against the
   PROPOSED new revisions. Build the proposed state by substituting the new revisions for
   the repointed refs in the session's installed set.
4. If any dependent fails conformance against the proposed state: REJECT with
   `{:repoint_blocked, ref, [{dependent_name, failures}]}`. NO install records are written.
5. Only if ALL dependents pass: execute the existing write loop (line 250-263) to flip
   install records to the new revisions.

This is the "preflight then flip" pattern -- the session is never left in an inconsistent
state. Repoint of R updates the one shared record, and every dependent is re-validated
against the proposed new revision BEFORE the flip. No per-dependent locks.

**Consequence for partial success:** If two refs are repointed and only one's dependents
pass, the ENTIRE repoint is rejected (all-or-nothing). The operator resolves the conflict
by upgrading the failing dependent or choosing a compatible revision, then retries.

**Error contracts:** New error tuples ride the existing `{:error, reason}` pattern used by
`seed_install/6`, `repoint_template_installs/4`, and Conformance checks. No new error protocol.

### M3-d: Merged conflict analysis

The merged rule+role set of all composed socialwares goes through the SAME role-DAG Conformance
check M1 already built (`check_with_warnings/2`, conformance.ex:50-54).

**What M3 adds for `requires`:**

1. **Merged role-DAG analysis:** The combined routing rules from all installed socialwares
   form a single graph. Conformance runs `check_role_dag/1` (conformance.ex:348-367) over the
   merged set -- cycles, double-delivery, dead roles spanning socialware boundaries are caught.

2. **Role name collision across composed definitions (REJECT):** Under A-2 auto-prefix, role
   name collisions should be zero by construction -- `hello:advisor` and `kanban:advisor` are
   different strings. This gate catches unprefixed legacy roles or framework bugs. If two
   composed socialwares declare the same unprefixed role_name, reject with
   `{:role_name_collision, role_name, [socialware_a, socialware_b]}`.

3. **Cross-reference validation:** A routing rule in socialware A referencing a prefixed role
   from socialware B (e.g. `orchestrator:coordinator`) is valid iff A `requires` B and B
   declares that role. The existing `check_routing_receivers/1` (conformance.ex:324-335)
   already validates receiver role names against declared roles; M3 extends the declared set
   to include roles from all transitively required socialwares for the socialware being checked.

### M3-e: SessionTemplate evolves

Template's `installs` goes from "the whole composition specification" to "the entry point."

**Before M3:** Template declares every socialware in `installs`. The author must know and list
the full transitive closure.

```yaml
installs: [chat, orchestrator, hello, kanban]  # author must know the full set
```

**After M3:** Template declares one or more entry socialwares; their `requires` pull in the rest.

```yaml
installs: [chat, orchestrator, hello]  # hello requires orchestrator; orchestrator is already listed
# or even:
installs: [chat, hello]  # hello requires orchestrator → orchestrator installed transitively
```

**Backward compatibility:** Templates without `orchestrator` in `installs` still work if any
installed socialware `requires` it. The orchestration ref design says the orchestrator
Definition should be in the default template's installs (already done in M2,
`orchestrator.ex:167`). Existing templates are unaffected -- they list what they list, and the
requires closure fills in the rest.

**`default_installs`** (installation.ex:12): remains `["chat"]`. The orchestrator is pulled in
by socialwares that require it, or by the explicit install in `orchestrator.ex:167`.

**`freeze_template_installs/2`** (installation.ex:111-116): M3 extends freeze to expand the
transitive requires closure INTO the frozen installs list. When a template declares
`installs: [chat, hello]` and `hello` requires `orchestrator`, freeze:

1. Resolves each entry-point install to its current revision (existing behavior).
2. For each resolved definition, reads its `requires` field and resolves those names
   transitively via `DefinitionRegistry.lookup/2`.
3. Adds the resolved transitive requirements to the frozen installs list (deduplicating
   by ref name -- if `orchestrator` is already in the list, it keeps its existing pin).

The resulting frozen template content carries the FULL closure, so repair/re-materialization
resolves every install from a frozen pin, never live. This preserves the freeze-pin
invariant: a session created from this frozen template always gets the exact same revisions
of every socialware, including transitively required ones.

Without this expansion, a repair would resolve transitive requirements live -- a later
publish of `orchestrator` would change an existing session on repair, breaking the
freeze-pin contract (SPEC Section 4.2).

---

## 3. Interaction with existing machinery

### 3.1 ManifestResolver.resolve/1

`apps/ezagent_domain_session/lib/ezagent/socialware/manifest_resolver.ex:14-23`

Already validates `uses` (lines 27-38) and resolves views (lines 51-69). M3 extends:

- Add `requires/1` validation (same shape as `uses/1` -- list of non-empty strings)
- Add `ensure_required_published/2` -- each required socialware name must be published
  in the workspace (call `DefinitionRegistry.lookup/2`; fail-closed on missing)
- The required socialware does NOT need to be installed on any session at resolve time --
  only PUBLISHED. Install-time resolution handles the actual session materialization.

### 3.2 Conformance -- new APIs for `requires`

`apps/ezagent_domain_session/lib/ezagent/socialware/conformance.ex:64-78`

#### 3.2.1 check_candidate/2 extensions

`check_candidate/2` already runs every assertion for a not-yet-published candidate. M3 adds:

- `:requires_published` -- each required name is resolvable via `DefinitionRegistry.lookup/2`
- `:requires_cycle_free` -- the requires graph (including the candidate) has no cycles;
  build the transitive closure; if the candidate's own name appears, reject with the cycle path
- Cross-reference validation (role name in routing_rules from a required socialware actually
  exists in that socialware's Definition -- extends `check_routing_receivers/1` with the
  required socialwares' declared role names)

#### 3.2.2 check_against_installed/3 (NEW)

For version-conflict detection at install/repoint time. Takes a candidate Definition, a
workspace URI, and an `installed_map` of `%{name => %Definition{}}` representing the
session's currently installed socialwares:

```elixir
@spec check_against_installed(Definition.t(), URI.t() | String.t(), %{String.t() => Definition.t()}) ::
        :ok | {:error, [failure()]}
def check_against_installed(%Definition{} = candidate, workspace_uri, installed_map)
```

Uses the `installed_map` as the lookup context for all definition references (replaces the
real `DefinitionRegistry.lookup/2` for any name present in the map). This allows checking
whether a candidate is compatible with a specific set of installed revisions without
requiring those revisions to be the "current published" ones.

This is the API that `ensure_requirements/5` (Section 3.3) and repoint preflight
(Section 3.5) call to validate compatibility before proceeding.

#### 3.2.3 check_merged/2 (NEW)

For merged role-DAG analysis across composed socialwares (M3-d). Takes a list of
`%Definition{}` and a workspace URI, and runs the role-DAG checks over the MERGED
graph of all definitions:

```elixir
@spec check_merged([Definition.t()], URI.t() | String.t()) ::
        {:ok, [warning()]} | {:error, [failure()], [warning()]}
def check_merged(definitions, workspace_uri)
```

Builds a single merged graph:

- **Nodes:** all declared roles from all definitions (with A-2 auto-prefix, these are
  already prefixed: `hello:builder`, `orchestrator:orchestrator`)
- **Edges:** all routing rules from all definitions, with their source/target roles
- **Role name collision check (REJECT):** if two definitions declare the same unprefixed
  role_name and auto-prefix hasn't been applied yet, reject with
  `{:role_name_collision, role_name, [def_a, def_b]}`. Under A-2 auto-prefix, this
  should be zero-collision by construction; the gate catches unprefixed legacy.
- Then runs the existing `check_role_dag/1` graph analysis (cycles, double-delivery,
  dead roles) over the merged edge set. Cross-socialware cycles and conflicts that
  per-definition checking would miss are caught here.

This replaces the per-definition aggregation approach -- one graph, one analysis pass,
all socialware boundaries visible.

### 3.3 Installation.seed_install/6

`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:466-492`

M3 adds a recursive install loop that respects the existing idempotency guard:

```
defp seed_install(session_uri, workspace_uri, definition, object, install, actor_uri) do
  ref = install.ref

  case install_state(session_uri, ref) do
    :installed ->
      # Idempotency guard FIRST (preserves freeze-pin contract). Even
      # when the main install no-ops, ensure transitive requirements are
      # present -- a repoint of a dependent may have added new requires
      # that weren't there before.
      with :ok <- ensure_requirements(session_uri, workspace_uri, definition, actor_uri) do
        {:ok, :exists}
      end

    :removed ->
      # Ensure requirements, then repoint.
      with :ok <- ensure_requirements(session_uri, workspace_uri, definition, actor_uri) do
        point_session_install(session_uri, workspace_uri, install, definition, object, actor_uri)
      end

    :none ->
      # Ensure requirements first (topological: deps before dependent),
      # then seed the install.
      with :ok <- ensure_requirements(session_uri, workspace_uri, definition, actor_uri) do
        do_seed_install(session_uri, workspace_uri, definition, object, install, actor_uri)
      end
  end
end
```

Key properties of this ordering:

- **Idempotency guard FIRST** for S itself -- the freeze-pin contract is preserved; an
  already-installed S is a no-op for its own install record. The guard runs before any
  requirements work.
- **Requirements are still ensured** even when S is already installed (`:installed` branch)
  because a newer revision of S (installed via repoint) may declare new `requires` that
  weren't in the old revision. The per-requirement `seed_install` call has its OWN
  idempotency guard, so already-installed requirements no-op individually.
- **Cycle safety:** Conformance rejects requires cycles at publish time
  (`:requires_cycle_free` assertion). By install time, the requires graph is guaranteed
  acyclic, so the recursive install terminates. The (session, ref) idempotency guard on
  each requirement's own `seed_install` is a defense-in-depth backstop -- if a cycle
  somehow reached install time, the second visit to S would hit `:installed` and no-op
  instead of infinite-recursing.
- **Topological order:** Requirements are resolved in topological order (deps before
  dependents) so each required socialware's own transitive requires are fully installed
  before the dependent is seeded.

**Version conflict check:** During `ensure_requirements/5`, for each required socialware R:

1. If R is not installed: install it (normal seed_install path).
2. If R IS installed: run `check_against_installed/3` (new Conformance API, see Section 3.2)
   passing the dependent S as the candidate and the session's installed definitions as context.
   If S's conformance passes against the installed R: no conflict, proceed.
3. If S's conformance fails against the installed R: REJECT with
   `{:version_conflict, r_name, [s_name | other_dependents]}`.

### 3.4 Boot manifest scan

`apps/ezagent_domain_session/lib/ezagent/socialware/manifest_seed.ex:63-72` -- `scan_all!/1`

Already scans `$EZAGENT_HOME/<profile>/socialware/*/manifest.yaml` and
`priv/socialware/*/manifest.yaml` for every started OTP app. M3 doesn't change the scan -- the
same directories are swept. What changes: when a scanned manifest has `requires`, the import
path (`import_manifest_path/1`, line 133) now validates those requires via the extended
`ManifestResolver.resolve/1`, and `ConfigGovernance.Socialware.publish_or_upgrade/2` receives
a Definition with `requires` populated.

### 3.5 Repoint preflight re-validation

`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:237-264` --
`repoint_template_installs/4`

Extended with PREFLIGHT conformance re-validation (see M3-c). BEFORE the write loop:
resolve the new revisions, compute reverse deps of ALL repointed refs, run
`check_against_installed/3` for each dependent against the proposed new state. If
any dependent fails, reject WITHOUT writing any install records (all-or-nothing).
Only if ALL pass does the existing write loop execute. See M3-c for the full algorithm.

### 3.6 Definition struct

`apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:11-28`

New field `requires: []` (default empty list, line 17 area). Added to:

- `@enforce_keys` -- NOT added (optional field, defaults to `[]`)
- `new/1` -- validated via `string_list(attrs, :requires)` (reuses the same validator)
- `body/1` -- serialized as `requires: definition.requires`
- `content_hash/1` -- included transitively via `body/1`
- `@type t` -- `requires: [String.t()]`

`string_list/3` (lines 193-205) handles empty list, non-empty strings, and rejects invalid
entries. No new validator needed.

---

## 4. Out of scope

- **Cross-SESSION socialware communication.** Composed socialwares share ONE session.
  Cross-session communication is a different problem with existing sender-rule primitives;
  `requires` is about composition within a session.
- **The deploy-seed mechanism** (#1226, jjkysy's lane). M3 doesn't touch how socialwares are
  deployed to the node.
- **`uses` granularity change.** Q3 already settled as whole-plugin -- `uses` stays as-is.
- **Per-dependent version locking.** Flat npm-hoist model (A-1); no per-dependent locks.
- **The optional accepted-tags declaration** from the orchestration ref design Section 6.
  Deferred to post-M3-dogfood evidence.
- **`from_role` runtime matcher** (M1 item). Already in the authority spec; M3 doesn't depend
  on it, but the merged role-DAG analysis is more precise once `from_role` exists.

---

## 5. Builder-verify notes

1. **Definition.new/1** -- add `requires` field to struct + `new/1` pipeline + `body/1` +
   `@type t`. Reuse existing `string_list/3` validator (definition.ex:193-205).
2. **ManifestResolver.resolve/1** -- add `requires` validation; check each required name is
   published in workspace via `DefinitionRegistry.lookup/2`. Fail-closed on unknown name.
3. **ManifestYaml.@top_level_order** (manifest_yaml.ex:18-36) -- add `"requires"` to the
   ordered key list so canonical render emits it and round-trip preserves it.
4. **Conformance** -- three additions:
   a) `check_candidate/2` gains `:requires_published` (each required name resolves in
      registry) and `:requires_cycle_free` (build transitive closure, detect cycle).
      Extend `check_routing_receivers/1` to include required socialwares' roles in the
      declared set.
   b) NEW `check_against_installed/3` -- takes candidate + workspace + `%{name => Definition}`
      installed map. Substitutes installed definitions for real registry lookups. Used by
      `ensure_requirements/5` and repoint preflight.
   c) NEW `check_merged/2` -- takes `[Definition.t()]` + workspace, builds merged role-DAG
      graph, runs cycle/double-delivery/dead-role analysis + role name collision check.
      Reuse existing graph primitives: either build a synthetic `%Definition{}` with merged
      roles+routing_rules and pass to `check_role_dag/1`, or extract the graph helpers
      (`role_edges/3`, cycle/double-delivery/dead-role functions) into shared internals
      (codex MINOR -- avoid duplication).
5. **Installation.seed_install/6** -- restructure to check idempotency guard FIRST, then
   `ensure_requirements/5` in each branch (`:installed` / `:removed` / `:none`). The
   `:installed` branch also ensures requirements (new requires may have been added by a
   repoint of the dependent). `ensure_requirements/5` resolves transitive closure, topo-sorts,
   calls `seed_install` for each requirement. Version conflict: if required socialware
   already installed at different hash, call `check_against_installed/3` with the dependent
   as candidate.
6. **Installation.repoint_template_installs/4** -- restructure to PREFLIGHT: resolve new
   revisions, compute reverse deps, run `check_against_installed/3` for each dependent
   against proposed state, then write only if all pass (all-or-nothing). Impl note
   (codex MINOR): current write loop is sequential `Enum.reduce_while`; preflight
   guarantees no writes for validation failures, but write failures mid-loop need a
   transaction or rollback story (can be deferred to an impl hardening pass since
   ConfigStore writes are individual and the partial-write window is narrow).
7. **Installation.freeze_template_installs/2** -- expand transitive requires closure into
   the frozen installs list so repair resolves everything from frozen pins. Dedupe by ref
   name preserves existing explicit pins.
8. **Error contracts** -- new error tuples:
   `{:version_conflict, socialware_name, dependent_names}`,
   `{:repoint_blocked, ref, [{dependent_name, failures}]}`,
   `{:unknown_socialware_requires, name}`,
   `{:requires_cycle, cycle_path}`,
   `{:role_name_collision, role_name, [socialware_names]}`.
   All ride the existing `{:error, reason}` pattern.
9. **Test plan** -- unit: Definition.new/1 with requires; ManifestResolver with missing/present
   requires; Conformance cycle detection + check_against_installed + check_merged;
   Installation recursive install with transitive requires + idempotency guard ordering;
   freeze expansion. Integration: hello + orchestrator compose via requires; repoint
   preflight rejection.
10. **Existing sessions are unaffected** -- `requires` defaults to `[]`; the transitive
    resolution only fires when the field is non-empty. Legacy definitions with no `requires`
    field behave identically.

## 6. Review history

| Round | Date | Verdict | Findings |
|-------|------|---------|----------|
| rev1 (codex) | 2026-07-07 | UNSOUND | 3 BLOCKER (idempotency guard ordering, repoint post-mutation, freeze-pin transitive gap), 2 MAJOR (conformance context API, merged DAG aggregation) |
| rev2 (codex) | 2026-07-07 | SOUND | 0 BLOCKER, 0 MAJOR, 2 MINOR (all-or-nothing atomicity, check_merged reuse -- both impl-concern, covered in builder-verify) |
