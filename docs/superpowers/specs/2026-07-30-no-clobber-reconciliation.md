# No-clobber reconciliation (hash-based) replacing skip-if-exists — implementation plan

*Follow-up ④ of the decentralization-hypothesis research
(`docs/notes/2026-07-30-decentralization-hypothesis.md`, #1636 — recommendation 4:
"Give every file/home-dir replica a content-hash reconciliation rule …
'skip-if-exists' is banned as a policy"). Planning doc only — no product code.
Baseline: origin/main @ 2026-07-30.*

---

## 1. Problem, grounded in the bug corpus

**#206 → #1633:** the socialware package store is a filesystem replica
(`$EZAGENT_HOME/<profile>/socialware/<name>/`, a persistent canary bind-mount that
survives DB resets) seeded from the release's `priv/socialware_seed/<name>/`.
Idempotency was directory-granular (`unless File.exists?(target), do: File.cp_r!`):
kanban's dir was materialized between `manifest.yaml` (07-08) and `recipes.yaml`
(07-16) shipping, so every later boot skipped the whole dir, `recipes.yaml` never
arrived, and `ManifestSeed.scan_all!/1` raised out of the last OTP `start/2` —
whole-node crash-loop. #1633 fixed the **missing-file** case (file-level
reconciliation) but explicitly deferred the **changed-file** case: the current
module states "a content-level CHANGE shipped in a later release of a builtin file
also does not overwrite an existing (even unedited) copy"
(`apps/ezagent_core/lib/ezagent/home/socialware_seed.ex:31–37`). A shipped fix to
a builtin file therefore never reaches an existing deployment — the same "frozen
at first deploy" failure class, one level down.

**#201/#1570 (flavor-store adopt-clobber, fixed by #1604):** the ETS/DB variant
of the same class — one slot, multiple writers, and a "skip/insert-if-absent"
(`put_new`) proposal that codex rejected as NEEDS-WORK (stale-on-URI-reuse;
error-undo deleting pre-existing rows). The final fix was an **ownership rule**
(only the spawn winner writes, gated on the core spawn receipt,
`apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex:542`), not a
smarter skip. Lesson for this plan: `put_new`/skip-if-exists is not a
reconciliation policy — every replica needs either a single owner or an explicit
hash-based reconcile rule.

**The class (research doc ③ bug #4, ⑥.4):** "shipped source vs persistently
deployed copy = two copies; the reconciliation rule was too coarse and owned by
nobody" — [B] duplication-without-owner. Local-first replicas without a
reconciliation rule default to skip-if-exists; the cure is content-hash
reconcile that distinguishes *stale-unedited* (refresh) from *operator-edited*
(preserve + warn), which is precisely the policy `DefinitionRegistry` and
`SkillSeed` already implement for their artifacts.

## 2. Current state — enumeration

### 2.1 The exemplars already in-tree (the design is proven, not invented)

| Site | Where | Policy |
|---|---|---|
| **`Ezagent.Home.SkillSeed`** | `apps/ezagent_core/lib/ezagent/home/skill_seed.ex:130–166` (`seed_one` / `reconcile_existing`) | **The exact target pattern**: per-ref `shipped_hash` ledger (ConfigStore seed objects, `maybe_upsert_index` :186+) + 3-way compare (`on_disk_hash` vs stored `shipped_hash` vs `release_hash`): absent→seed; unedited+unchanged→`:exists`; unedited+changed→atomic staged **upgrade**; edited→`:preserved` (+ `warn_skipped_upgrade` when an upgrade was skipped); crash-safe `.staging-`/`.old-` replace + `recover!` |
| **`Ezagent.Socialware.DefinitionRegistry`** | `apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:10–57, 247–275` | DB-object variant: stored `content_hash` == code hash → no-op; diverged → **no-clobber** + `Logger.warning` + `[:ezagent, :socialware, :definition, :divergence]` telemetry + read-only `builtin_definition_divergences/0` report + explicit `--force` apply lane (Allen 2026-07-10) |
| **`Ezagent.Home.SkillReconcile`** | `apps/ezagent_domain_agent/lib/ezagent/home/skill_reconcile.ex:1–30` | The **CODE-owned** branch: per-agent skill copies are derived caches — "cover strategy": manual edits are overwritten *with telemetry* (hash 3-way identifies the edit); manifest-hash O(1) skip stamp |
| Atomic-replace infra | `apps/ezagent_core/lib/ezagent/agent/materializer.ex:80–115` (`atomic_replace` + `.bak` restore + marker `target_usable?` :195–203) | The staging/rollback primitive to reuse — not a violation site |

### 2.2 Remaining skip-if-exists sites (the worklist)

| # | Site | Pattern today | Owner class | Verdict |
|---|---|---|---|---|
| 1 | **`Ezagent.Home.SocialwareSeed.seed_one/2`** — `apps/ezagent_core/lib/ezagent/home/socialware_seed.ex:128–149` (`File.exists?(d) -> :ok`) | file-level copy-if-missing; changed-file case deferred by #1633; **no ledger** → cannot distinguish operator-edit from stale-unedited | mixed: builtin files are CODE-shipped, but operator edits are contractually preserved (tests `apps/ezagent_core/test/ezagent/home/socialware_seed_test.exs:34–43, 75–97`) | **Target 1 — adopt the SkillSeed 3-way reconcile at file granularity** |
| 2 | **`CcOrchestratorSeed.write_soft_sandbox_files`** — `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex:268` (`unless File.exists?(settings_path)`) | write-once `settings.json`; NOTE the sibling persona is already managed rewrite-on-diff (`refresh_managed_persona!` :285–296 — a codex-review fix for exactly this staleness) | CODE-owned (seed sandbox is "fully managed") | Target 2 — managed-content contract (hash or rewrite-on-diff) |
| 3 | **`CodexOrchestratorSeed.ensure_sandbox_files`** — `apps/ezagent_plugin_codex/lib/ezagent/orchestrator/codex_orchestrator_seed.ex:78` (`unless File.exists?(config.toml)`) — **and** the inverse defect at :77: `AGENTS.md` is **unconditionally overwritten**, clobbering any operator edit | write-once + adopt-clobber side by side in one function | CODE-owned persona / operator-editable config | Target 2 — align both files with the cc managed-persona contract |
| 4 | `mix ezagent.demo.seed_cc_sandbox` — `apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_sandbox.ex:162` (`File.exists?(dest) and not force?`) | dir-level skip + explicit `--force` | demo tooling | low priority; gate-allowlisted with a TODO |
| 5 | `Ezagent.Home.Migration` — `apps/ezagent_core/lib/ezagent/home/migration.ex:173, 294` | skip when destination exists non-empty | one-shot layout migration — skip **is** the correct semantics | classify + exempt (documented) |
| 6 | `Credential.HomeRuntime.materialize_single_reference` marker short-circuit — `apps/ezagent_core/lib/ezagent/credential/home_runtime.ex:629–645` | `.ezagent-config-complete` marker skip | operator/credential-owned; declared **ZERO-CHANGE** by SkillReconcile's hard constraint (its moduledoc) | out of scope; must stay |
| 7 | Registry `put_new` (KindRegistry `apps/ezagent_actor/lib/ezagent/kind_registry.ex`, RoutingRegistry, TemplateRegistry strict-dup) | put_new-for-unique-key | **constitutive of the actor model** (research ⑥.8) | explicitly NOT in scope; the gate must never flag these |

### 2.3 The contract that must not break

`socialware_seed_test.exs:34` ("a pre-existing package dir is NOT overwritten
(respects operator edits)") and `:75–97` (new-sibling-file arrives while the
existing edited file "was never touched — operator-edit guarantee"). Both stay
green verbatim through every phase: the new policy refreshes **only** files whose
on-disk hash equals the recorded last-shipped hash. An operator-edited file is
preserved in exactly the cases the tests assert — the tests gain siblings, they
are not rewritten.

## 3. Design

### 3.1 The policy (per artifact = per file)

For each shipped artifact, keep the **last-shipped content hash** in a ledger.
On every seed/redeploy:

| dest state | vs ledger | action |
|---|---|---|
| absent | — | seed (copy), record shipped hash |
| present, `hash(dest) == last_shipped` | `hash(release) == last_shipped` | no-op |
| present, `hash(dest) == last_shipped` | `hash(release) != last_shipped` | **refresh** (atomic staged replace), record new shipped hash |
| present, `hash(dest) != last_shipped` | any | **preserve** + `Logger.warning` + telemetry divergence event (+ explicit-apply lane, §3.4) |

This is `SkillSeed.reconcile_existing/5` verbatim, generalized from
directory-granular refs to file-granular package content. It is the durable
answer to #1633's deferred changed-file case: a shipped fix reaches every
unedited deployment on the next boot, and a deliberate operator edit survives
redeploy loudly instead of silently.

### 3.2 Shared primitive

Extract the 3-way decision + atomic replace + ledger read/write into one core
helper (working name `Ezagent.Home.ShippedReconcile`; final name per
self-explained-naming review), consumed by `SocialwareSeed`, `SkillSeed`
(refactor onto it, behavior-identical), and the orchestrator sandbox seeds.
`DefinitionRegistry` (DB objects, already correct) and `SkillReconcile`
(CODE-owned cover strategy, already correct) stay as-is but are named in the
module doc as the two sanctioned variants of the same policy.

**Ledger home — the one real design fork (§5 Q1):**
`SocialwareSeed` must run from the Category-A `mix ezagent.home.init` bootstrap
— *"purely filesystem work (no Repo, no dispatch)"* (`socialware_seed.ex:39–42`)
— so the SkillSeed ConfigStore ledger is not available at its earliest call
site. Options:

- **(a) Sidecar manifest per package dir** (e.g. `.ezagent-shipped-manifest`,
  `relpath → sha256`, same family as SkillReconcile's
  `.ezagent-skills-manifest`): works Repo-less, travels with the bind-mount,
  survives DB resets — **recommended**.
- (b) ConfigStore seed objects (SkillSeed-style) written only on the boot-path
  call, with the bootstrap call staying ledger-less (first boot backfills):
  keeps ledgers in one store but splits behavior by call site — rejected
  (two-mode seeding is how #206 happened).

### 3.3 First-encounter backfill (existing deployments have no ledger)

On the first ledgered pass over a pre-existing dest file:
`hash(dest) == hash(release)` → adopt as shipped (record, unedited);
otherwise → **preserve + warn + record `assumed_operator_edited`** (provenance
unprovable — we never guess in favor of clobbering). Matches the operator-edit
contract and makes the warning stream the honest inventory of divergent files on
canary. No attempt to match against historical release hashes (no such archive
exists; complexity unjustified).

### 3.4 Divergence surfacing + explicit apply lane

Mirror `DefinitionRegistry`: one telemetry event
(`[:ezagent, :home, :shipped_reconcile, :divergence]` with site/package/relpath/
hashes), a read-only report (`mix ezagent.home.divergences`), and an explicit
per-file force-apply (`mix ezagent.home.apply --package <name> --file <relpath>`)
so an operator resolves a diverged builtin deliberately — never automatically.

### 3.5 Sequencing

- **P1 — `SocialwareSeed` on the shared primitive** (the #206/#1633 class
  closer): sidecar ledger, 3-way per file, atomic staged replace (reuse
  Materializer staging pattern), backfill rule §3.3. Existing operator-edit
  tests untouched; new tests per §3.6.
- **P2 — orchestrator sandbox seeds**: cc `settings.json` + codex `config.toml`
  onto the primitive; fix codex `AGENTS.md` adopt-clobber by porting the cc
  `refresh_managed_persona!` contract (managed rewrite-on-diff — it is
  CODE-owned, so cover-with-telemetry, not preserve).
- **P3 — CI gate + classification residue**: land the gate (§3.7) with its
  enumerated allowlist (#4/#5/#6 of §2.2 + registries), SkillSeed refactored
  onto the primitive, ARCHITECTURE.md Decision-Log entry declaring
  "skip-if-exists is banned as a reconciliation policy; replicas get a hash
  ledger or a single owner".
- Out of scope: `HomeRuntime` marker gate (hard ZERO-CHANGE constraint),
  `Home.Migration` (one-shot semantics), registry `put_new` (constitutive),
  flavor store (#1604 ownership fix is complete — cited as corpus, not work).

### 3.6 Acceptance

- P1: failing-first reproduction of the deferred case — ship v1 of a builtin
  file, deploy, ship changed v2, re-seed → **unedited dest refreshed** (red on
  main today, per `socialware_seed.ex:31–37`); edited dest preserved + warned +
  telemetry; missing-file case still heals (#1633 tests green);
  `socialware_seed_test.exs:34, 75` green verbatim; ledger-less backfill test
  (§3.3 both branches); crash-mid-replace recovery test (staging residue).
- P2: codex `AGENTS.md` operator-edit-vs-persona-drift test (currently
  impossible to pass — it clobbers); cc `settings.json` refresh-on-new-release
  test.
- P3: gate red on a synthetic `unless File.exists?` copy-skip in a seed module,
  green on baseline; allowlist can only shrink.

### 3.7 CI gate — forbid new bare skip-if-exists

Invariant-test style (same as `cap_absorb_reachability_test.exs`: scan
`apps/**/*.ex`, explicit allowlist, runs in `mix ci.fast`):

- **G1:** in any module whose source both writes files (`File.cp`/`File.cp_r`/
  `File.write`) and tests existence (`File.exists?`/`File.dir?`) on the same
  path family, the write must route through the shared primitive (module
  attribute marker or import), OR the file is on the enumerated allowlist
  (§2.2 #4/#5/#6). Baseline produced by an **empty-allowlist run**
  (enumerator-gate discipline); allowlist shrinks only.
- **G2:** store-level twin — `Map.put_new`/`put_new`-style insert-if-absent on
  *durable replica stores* outside the registry allowlist (KindRegistry /
  RoutingRegistry / TemplateRegistry are constitutive and exempt by path) —
  the #201 `put_new` trap. This is a narrow path-scoped grep, not a repo-wide
  put_new ban (put_new on in-memory option maps is fine).
- **G3:** gate failure message links this spec + the Decision-Log entry.

## 4. What this plan deliberately preserves

- The operator-edit-survives-redeploy contract, now *stronger*: preserved **and
  visible** (warn + telemetry + report) instead of preserved-and-silent.
- `DefinitionRegistry`'s default-no-clobber + explicit-force model — the policy
  template, untouched.
- The #1633 file-level missing-file self-heal — subsumed, not replaced.
- `SkillReconcile`'s cover strategy for CODE-owned derived caches — the
  ownership classification (§2.2 column 4) is part of the design, per site.

## 5. Open questions for Allen

1. **Ledger home (§3.2):** sidecar per-package manifest file (recommended:
   Repo-less bootstrap works, survives DB reset with the bind-mount) vs
   ConfigStore objects (one store, but splits bootstrap/boot behavior)?
2. **First-encounter rule (§3.3):** confirm "hash-match → adopt as shipped;
   mismatch → preserve + warn as assumed-edited" — or do you want mismatches to
   block boot on canary once, forcing a one-time operator sweep?
3. **Codex `AGENTS.md` (§2.2 #3):** confirm it is CODE-owned/managed (cover on
   drift, cc-persona style). If operators are expected to hand-tune it
   per-deployment, it flips to preserve+warn instead.
4. **Force-apply lane (§3.4):** per-file `mix ezagent.home.apply` enough, or do
   you want a bulk `--all-unedited` mode for release upgrades?
5. **Gate scope (§3.7 G2):** is the narrow durable-store `put_new` gate worth
   its allowlist maintenance now, or defer G2 to when the next store-shaped
   replica appears (G1 alone closes the file-replica class)?
