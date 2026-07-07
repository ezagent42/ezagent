# Install/Conformance Reliability Bundle — ⑧ silent-narrowing gate + ⑨ install atomicity (design)

- **Date**: 2026-07-07
- **Authority**: `docs/together/2026-07-06/handoffs/system-mechanism-feedback.md` items ⑧, ⑨ + Appendix B (coordinator re-verified at main `bd5c6b5`); jjkysy #1201.
- **Scope**: one small PR. Three fixes + three invariant tests. No new subsystems.
- **Status**: draft — pending codex adversarial review

## 0. Re-grounding vs #1213 (read this first)

The handoff was written before #1213 (`2bc8b5149`) landed. Coordinator Appendix B verified
against `bd5c6b5`, but #1213 **touched the exact cond this spec targets** — the current
main state differs from both write-ups:

- `mix/tasks/ezagent.socialware.check.ex:88-100` now has a **three-branch cond**
  (blame: branches added by `2bc8b5149`):
  1. `function_exported?(DefinitionRegistry, :list_names, 1)` → **dead** (the function
     has never existed; `definition_registry.ex` has only `list/1` at `:262`);
  2. `function_exported?(DefinitionRegistry, :list, 1)` → **this branch fires today**,
     enumerating via `list/1`;
  3. `true -> ["chat", "socialware"]` — the hardcoded fallback at `:99`, **currently
     dead** but still present.

So ⑧ is no longer "the gate checks only two names" — #1213 de-facto fixed the
enumeration. What remains is the **false-green machinery itself**: two
`function_exported?` probes guarding a compile-time-known module, a hardcoded fallback
that resurrects silent narrowing the day `list/1` is renamed, and a second silent-drop
path (§1.2). ⑨ is unchanged by #1213 and holds as written.

## 1. Item ⑧ — conformance gate must not be able to silently narrow

### 1.1 X (why)

A conformance gate that silently no-ops on a missing function is a false-green machine:
a NEW socialware can be broken and the gate says fine. The `function_exported?` probe
pattern is exactly that machine — it converts an API drift (rename `list/1`, change its
arity) into a silent regression to a two-name hardcoded list, with a green CI. The gate
is wired into `ci.local`/precommit precisely to be trusted; a gate that can lie is worse
than no gate.

### 1.2 Current state (verified on `docs/spec-t4` base = `dcabf6174`)

- `check.ex:88-100` — the cond described in §0. Note the same file **already calls
  `DefinitionRegistry.lookup/2` directly** (`check.ex:70`), so the probe dance was never
  a real dependency boundary — `DefinitionRegistry` is a hard compile-time reference of
  this task either way.
- Second silent-drop path: `resolve_definitions([], workspace_uri)` (`check.ex:79-87`)
  `flat_map`s over names and **drops `:error` lookups silently** — a name that `list/1`
  returned but `lookup/2` cannot resolve vanishes from the checked set instead of
  failing the gate.
- `DefinitionRegistry.list/1` (`definition_registry.ex:262`) returns entry maps with
  `.name`, spanning caller-workspace + system-workspace + public definitions, excluding
  retracted ones (`list_entry_for/3` at `:376`, `visible_to_workspace?/4` at `:398`).
  For the CI invocation (system workspace) this is the full published set.

### 1.3 Design — DELETE the fallback (let-it-crash), fail loud on lookup misses

Answering the task's question directly: **yes, delete the fallback** — do not add
`list_names/1`. The handoff's "one-line fix: add `list_names/1`" predates #1213; now
that branch 2 exists and fires, adding `list_names/1` would only switch which probe
branch runs while keeping the false-green machinery alive. Instead:

1. Replace `all_definition_names/2` with a direct call:

   ```elixir
   defp all_definition_names(workspace_uri) do
     workspace_uri |> DefinitionRegistry.list() |> Enum.map(& &1.name)
   end
   ```

   No `cond`, no `function_exported?`, no hardcoded names. If the registry API drifts,
   the task **fails to compile** — the loudest possible failure, per let-it-crash
   doctrine. (Precedent: `lookup/2` is already called directly in the same file.)

2. Make `resolve_definitions([], ws)` fail loud on a lookup miss: a name enumerated by
   `list/1` whose `lookup/2` returns `:error` is `Mix.raise`d (name + workspace in the
   message), not dropped. Between `list` and `lookup` sits real logic (retraction
   markers, revision pointers); a divergence is a registry-consistency bug the gate
   must surface, not paper over.

3. Keep `seed_builtins/0`'s `function_exported?` probe **as-is**: it guards an
   *optional* seeding helper, not the enumeration contract, and its absence makes the
   gate *stricter* (nothing seeded → check still enumerates whatever is published).
   Fallback-deletion applies to the narrowing path only. **Builder note**: on current
   main `seed_builtin_definitions/0` does exist, so the probe is live-true; if the
   builder finds it equally load-bearing (always true), collapsing it to a direct call
   is in-scope cleanup, not required by this spec.

Non-goal: changing `list/1` visibility semantics. Per-workspace scoping is the intended
contract; the CI gate runs against the system workspace and sees the full builtin +
boot-seeded set.

### 1.4 Invariant tests (⑧)

- **T8a — a third published definition IS checked**: in a test workspace, publish a
  third definition (beyond the two builtins) with a deliberately broken reference
  (e.g. a role recipe that does not resolve); run the gate's enumeration + check path;
  assert the result set **contains the third name** and the overall verdict is red.
  This is the invariant the original defect violated: a new socialware cannot be
  outside the gate.
- **T8b — no narrowing, ever**: assert the checked-name set equals
  `DefinitionRegistry.list(ws) |> Enum.map(& &1.name)` exactly (publish N≥3 defs,
  compare sets). With the cond deleted this is near-tautological — which is the point:
  the test pins the contract so a future "helpful" fallback reintroduction goes red.
- **T8c — fallback removal proven**: the compile-time reference is the structural
  proof; the regression tripwire is a source assertion that
  `mix/tasks/ezagent.socialware.check.ex` contains no `function_exported?` probe on the
  enumeration path and no hardcoded definition-name list (same family as the existing
  architecture source-gates, e.g. `ViewAuthorizeGateTest`). Builder may fold T8c into
  an existing arch-gate file rather than a new one.

Test placement: the mix task is a thin wrapper; extract `all_definition_names/1` +
`resolve_definitions/2` into a testable seam only if needed — running the task via
`Mix.Task.rerun` in a test with an in-test ConfigStore is equally acceptable (builder's
choice; keep it one file).

## 2. Item ⑨(i) — cc-headless missing from the config-dir namespace catalog

### 2.1 X (why)

The FsResolver type allowlist is immutable at boot by design (`registry.ex:373-385`) —
but a catalog that must be maintained by hand, with no invariant tying it to the set of
flavors that declare a namespace, WILL drift. It already has: `cc-headless` shipped a
`config_dir_namespace/0` and nobody re-derived the catalog. Result: materializing any
Definition role slot on the stock `cc-headless` flavor crashes at config-dir resolution
(`ConfigDir.path/2` → `resource://<ws>/cc-headless-agents/<name>` → no registered type).
Catalog completeness must be a test, not a review-time memory.

### 2.2 Current state (verified)

- `fs_resolver/registry.ex:386` — `@config_dir_namespaces ["cc", "codex", "codex-remote", "py"]`.
- Declarers of `config_dir_namespace/0`: `cc_agent.ex:200` → `"cc"`,
  `cc_headless_agent.ex:18` → `"cc-headless"` (module
  `Ezagent.PluginCc.Template.CcHeadlessAgent`, registered in the cc plugin's
  `template_classes/0`, `plugin_cc/application.ex:93-97`), `codex_agent.ex:23`,
  `codex_remote_agent.ex:21`, `py_agent.ex:75`. **`"cc-headless"` is absent from the
  catalog.**
- Namespace resolution seam: `Ezagent.Kind.Template.namespace_of/1`
  (`kind/template.ex:333-343`) — explicit callback, else `template_name/0` minus
  `.agent` suffix. Config-dir-owning detection:
  `RecipeMaterializer.config_dir_flavor?/1` (`recipe_materializer.ex:224-227`) =
  exports `config_dir_namespace/0` **or** `CredentialAdapter.credentialled?/1`.

### 2.3 Design

1. Add `"cc-headless"` to `@config_dir_namespaces` (one token). Boot registration then
   yields the `"cc-headless-agents"` type with the same `config_dir_authority/2`.
2. **Catalog-completeness invariant** (the actual fix — the token is just today's
   instance): a test that enumerates every registered Template Class and asserts each
   config-dir-owning flavor's namespace is served by the resolver. See §2.4.

Keep the catalog static (do NOT derive it at boot from plugin modules): the allowlist
being independent of plugin Application start-ordering is a load-bearing property the
comment at `registry.ex:379-384` already documents. The invariant test closes the drift
gap without giving up boot-immutability.

### 2.4 Invariant test (⑨-i)

**T9a — namespace catalog completeness**: for every plugin's `template_classes/0`
(union over the started plugin apps; start them the way `check.ex` starts
`@reference_apps`), filter `config_dir_flavor?/1`-true classes, map
`Template.namespace_of/1`, and assert `FsResolver` serves type `"<ns>-agents"` (probe
via a `FsResolver.resolve/2` of a synthetic `resource://<ws>/<ns>-agents/<name>` URI, or
via the registry's non-prod introspection — builder's choice; the assertion is
"resolves/registered", not string-list equality, so the test exercises the real
boundary). This test is **red on current main** (cc-headless) and goes red again the
day flavor N+1 forgets the token — the "NEXT flavor can't be forgotten" requirement.

Note `config_dir_flavor?/1` is deliberately the broader predicate (credentialled
flavors without an explicit namespace derive one via `namespace_of/1`) — matching what
materialization will actually request at spawn time, which is the invariant that
matters. Test lives in `ezagent_core` or a cross-app integration suite — builder
placement, but it must see the plugin apps (same pattern as existing cross-app tests).

## 3. Item ⑨(ii) — install must be transactional-in-effect

### 3.1 X (why)

Install must be fully materialized or fully absent. Partial residue poisons the session
table two ways: leaked routing rules route messages at a dead session's behest, and a
leaked install pointer makes a same-name recreate silently inherit the failed attempt's
frozen revision instead of freezing the current one. Idempotent-reconcile machinery
exists (`created_by` stamping, `find_by_identity`) — the defect is that the rollback's
reversal set is **incomplete**, not that the primitives are missing.

### 3.2 What install creates (verified enumeration)

Per session-create (`SessionCreator` finalize path, `session_creator.ex:560-640`):

| # | Write | Where | Reversed by `Rollback.rollback_session/3`? |
|---|-------|-------|--------------------------------------------|
| 1 | Session Kind + WorkspaceRegistry bind | `Kind.spawn` / bind | ✅ `rollback.ex:58-59` |
| 2 | Owner caps (orchestrator-admin; remove_participant / assign_role / participant_teardown) | Materializer grants | ✅ orchestrator-admin (`rollback.ex:96-125`); the others are session-instance-scoped (inert once the Kind is destroyed) or intentionally owner-shared — **builder-verify** (§5) |
| 3 | **Per-session install pointers** — ConfigStore layer `"session"`, key `install:<ref>`, subject `session_uri` (`installation.ex:439-452`, via `seed_object_if_no_pointer`) | `install_template_installs/4` | ❌ **the gap** |
| 4 | Routing rules — default table rows, `created_by = session_uri`, identity `(created_by, rule_set, position)` (`template_team.ex:265-300`, `rule_store.ex:343-363`) | `install_template_rule_sets` | ✅ `delete_session_rule_rows/1` (`rollback.ex:73-85`) |
| 5 | Members (owner join; spawned role members) | Materializer | ✅ `compensate_spawned_members/1` + Kind destroy |
| 6 | Session-slice state (legends, prompt templates, surface seed) | template_team | ✅ dies with the Kind (**builder-verify** prompt templates are slice-resident, §5) |
| 7 | Orchestrator arm (MCP registration, SessionManager, lineage) | orchestrator branch | ✅ `rollback.ex:24-51` |

Also verified: every rollback step runs inside `safe/1` (`rollback.ex:127-133`), which
swallows failures — rollback reports `:ok` even when a step failed. And ConfigStore has
**no delete/retract primitive** for pointers (`config_store.ex` public API:
`write_and_point`, `seed_object_if_no_pointer`, `put_pointer`, reads) — append-only by
design.

### 3.3 The failure shape (how the residue bites)

`installed?/2` (`installation.ex:330-341`) answers from the ConfigStore pointer;
`seed_install` (`installation.ex:430`) short-circuits `{:ok, :exists}` when true — by
design, to HOLD the freeze-pin across benign re-seeds. After a failed create + rollback,
the pointer survives (row 3 ❌). A same-name recreate (session URIs are deterministic
per name) then:

- re-seeds nothing — the session runs whatever revision the **failed** attempt froze
  (silently stale if the def was republished in between), and
- any repair depends on the operator knowing to run the explicit
  `repoint_template_installs/4` upgrade path — i.e. residue converts a clean recreate
  into a silent partial one. (The handoff's "rules dropped" symptom is this same
  residue observed from the dealscout flow; the rule rows themselves are reversed
  today — `rollback.ex:57` — the pointer is the unreversed write that de-syncs the
  recreate.)

### 3.4 Design — complete the reversal set; keep governance append-only

**Rollback contract** (the deliverable of this item): every write in §3.2's table is
keyed by the install scope (`session_uri`) and every rollback step is
delete-by-that-key and idempotent (re-running rollback on an already-rolled-back
session is a no-op). Concretely, one addition and one adjustment:

1. **Retract install pointers on rollback** — new `Rollback` step
   `retract_session_installs(session_uri)`: for each ConfigStore key
   `install:<ref>` under subject `session_uri`, repoint to a **tombstone revision**
   (append-only marker, body `%{"removed" => true}` family — the exact pattern the
   definition layer already uses for retraction, `definition_registry.ex:20-24`
   `@retract_key`). No history deletion; governance stays append-only.
   - `installed?/2` returns `false` when the current object is a tombstone.
   - `seed_install` re-seeds **over** a tombstone via `write_and_point` (fresh freeze →
     CURRENT published revision — exactly the semantics a recreate should have).
     Constraint: the deterministic `source_turn_id`
     (`"socialware-install:<session>:<ref>"`, `installation.ex:447`) must get an
     attempt-distinguishing component on the re-seed path, or the shared-seed collision
     guard misfires; shape is builder latitude (e.g. suffix the tombstone object id).
   - Enumeration of a session's install keys: `ConfigStore.list_keys_for_subject/1`
     (`config_store.ex:368`) filtered by the `install:` prefix — no new query API.
2. **Rollback self-honesty**: keep `safe/1` (a rollback must never crash the caller's
   error path) but **log each swallowed step failure at error level with the step
   name** (today the `rescue → :error` is fully silent). Full
   rollback-outcome-reporting/retry is out of scope; a grep-able error line is the
   proportional fix.

Explicit non-goals: no DB transaction spanning Kind-spawn + ConfigStore + RuleStore
("transactional-in-effect" = complete compensations, not 2PC); no changes to the
freeze-pin/`repoint` upgrade semantics for *live* sessions (`:exists` short-circuit
stays for non-tombstoned installs — the divergent-body collision-guard rationale at
`installation.ex:420-429` is untouched).

### 3.5 Invariant tests (⑨-ii)

- **T9b — failed install leaves zero residue**: drive a template create with ≥1
  routing rule + ≥1 install through the real finalize path with a late step forced to
  fail (inject after `install_template_installs` + rule install have run — builder
  picks the seam; the existing `{:error, reason} → rollback_session` arm at
  `session_creator.ex:621-630` is the path under test). Assert: (a) zero RuleStore rows
  with `created_by == session_uri`; (b) `installed?(session, ref) == false` for every
  declared ref; (c) rollback re-run is a no-op (idempotence).
- **T9c — recreate after failure is fresh**: after T9b's failure, republish the
  definition (new revision), recreate the same session name, assert the install
  pointer pins the **new** revision and the session's rules are present — the
  "either fully materialized or fully absent" invariant observed end-to-end.

## 4. Interaction with #1213's boot-scan (no conflict — verified)

#1213's boot lane (`ManifestSeed.scan_boot_manifests!`, default-on in dev/prod) imports
`priv/socialware/*/manifest.yaml` via `ManifestYaml.import`, which validates each
candidate with `Conformance.check_candidate/2` (`manifest_yaml.ex:72`,
`conformance.ex:65`) and **raises on failure** (fail-loud, consistent with this spec's
doctrine). The mix-task gate validates *published* definitions with `Conformance.check/2`
via the real registry. Both are thin parameterizations of the same
`check_with_lookup/3` pipeline (candidate-aware vs. registry `lookup_fun`) — this spec
touches only the task's *enumeration* (which names to check), never the shared pipeline
or `check_candidate`, so the boot scan is unaffected. Synergy worth stating: post-#1213
the import chokepoint means an unparseable published body should not exist, which is
why §1.3 does not re-litigate `list_entry_for/3`'s silent `Definition.new` exclusion —
any residual would be a #1213-lane bug, not this gate's.

## 5. Builder-verify notes

Impl residue deliberately left to the builder — verify at build time:

1. `seed_builtins/0` probe (§1.3.3): confirm `seed_builtin_definitions/0` existence and
   whether the probe collapses to a direct call.
2. Row-2 caps (§3.2): confirm remove_participant/assign_role caps are
   session-instance-scoped (inert post-destroy) and participant_teardown is the
   intentionally-shared owner cap — if any is live-registry-resident and
   session-scoped, add its revoke to the rollback reversal set.
3. Row-6 (§3.2): confirm prompt-template installs are session-slice (die with the
   Kind), not global `PromptTemplate` rows; if global, they join the reversal set
   keyed by session scope.
4. Tombstone body shape + `installed?/2` predicate: mirror the `@retract_key` marker
   conventions (`definition_registry.ex:20-24`) rather than inventing a second
   tombstone dialect; confirm `resolve/4` surfaces enough of the current body to test
   tombstone-ness cheaply.
5. T9a probe mechanics: prefer `FsResolver.resolve/2` against a synthetic URI over the
   non-prod `register_for_test` introspection if both work; assert failure mode is a
   loud `{:error, ...}`/raise, not a nil.
6. Line numbers cited here were verified at `dcabf6174`; re-verify on rebase.

## 6. Out of scope

- `list/1` visibility semantics; multi-workspace gate sweeps.
- Rollback outcome reporting/retry machinery beyond the error log line.
- The ⑨ handoff's cc-headless *runtime* (sidecar) behavior — only the namespace
  catalog entry.
- Any change to freeze-pin (§4.x SPEC) semantics for live sessions.
