# Retire prod auto-seed — one governed import with authorized force — spec

*Follow-up ④ of the decentralization-hypothesis research
(`docs/notes/2026-07-30-decentralization-hypothesis.md`, #1636 — recommendation 4).
Planning doc only — no product code. Baseline: origin/main @ 2026-07-30.*

> ## Grill outcome (2026-07-30)
>
> Allen grilled the original framing ("hash-based no-clobber reconciliation
> replacing skip-if-exists") and the X was re-pinned. **The X is NOT "refresh
> the home file correctly" and the answer is NOT a 3-way hash merge.** Allen's
> decision: **DECOUPLE data-import from deploy — RETIRE prod auto-seed
> entirely.** One governed import mechanism (ezagent's existing
> `import_remote` lane); default = **ERROR if the artifact already exists**
> (no silent skip, no silent clobber); an explicit, **cap-authorized +
> audited `force`** deletes-old + overwrites, with the developer obligated to
> extract/handle old data BEFORE forcing. The same mechanism serves fresh-prod
> bootstrap AND upgrade. No definition-vs-instance distinction (the
> official-site is in scope too). No hash reconciliation, no shipped-hash
> ledger, no 3-way compare. **Direction changed from INVENT (a reconcile
> engine) → RETIRE (the auto-seed that made reconciliation necessary).**
> This converges with zyli's **#1642** (CI `release.yaml` acknowledgement
> gate = the "you changed it, acknowledge it" step before force). The spec
> below SHRINKS accordingly; the bug corpus (§1) stands unchanged.

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
reconciliation) but explicitly deferred the **changed-file** case: the module
states that a content-level CHANGE shipped in a later release of a builtin file
does not overwrite an existing (even unedited) copy
(`apps/ezagent_core/lib/ezagent/home/socialware_seed.ex`, moduledoc). A shipped
fix to a builtin file therefore never reaches an existing deployment — "frozen
at first deploy," one level down.

**#201/#1570 (flavor-store adopt-clobber, fixed by #1604):** the ETS/DB variant
of the same class — one slot, multiple writers, and a "skip/insert-if-absent"
(`put_new`) proposal that codex rejected as NEEDS-WORK (stale-on-URI-reuse;
error-undo deleting pre-existing rows). The final fix was an **ownership rule**
(only the spawn winner writes, gated on the core spawn receipt), not a smarter
skip.

**The class (research doc ③ bug #4, ⑥.4):** "shipped source vs persistently
deployed copy = two copies; the reconciliation rule was too coarse and owned by
nobody" — [B] duplication-without-owner.

**The grill's reframe of the class:** the original plan (and the research
recommendation) treated "two copies exist, reconcile them better" as the given
and proposed a hash ledger to arbitrate. Allen rejected the given: **the second
copy only exists because deploy auto-seeds data.** Every boot of every release
re-runs an unowned, implicit import — THAT is the writer with no owner. Remove
the auto-writer and there is nothing left to reconcile: data enters production
through exactly one explicit, governed, audited door.

## 2. Current state — the auto-seed pipeline to retire (verified this session)

| Piece | Where | Today |
|---|---|---|
| **Boot-scan auto-seed flag** | `config/config.exs:38` — `socialware_manifest_boot_scan: config_env() in [:dev, :prod]` | Prod auto-imports socialware manifests on EVERY boot (test opts out, `config/test.exs:173`). This is the flag whose prod leg retires. |
| **File-copy seed** | `Ezagent.Home.SocialwareSeed` (`apps/ezagent_core/lib/ezagent/home/socialware_seed.ex`) — scans every loaded OTP app's `priv/socialware_seed/`, copies into `$EZAGENT_HOME`; file-level missing-file heal (#1633); changed-file overwrite explicitly NOT done (moduledoc) | Runs from `mix ezagent.home.init` bootstrap AND the boot fallback in `ManifestSeed`. The implicit prod writer. |
| **Governed import lane (the keeper)** | `Ezagent.Socialware.ManifestSeed.import_package/2`, driven by `mix ezagent.socialware.import_remote` (`apps/ezagent_cli/lib/mix/tasks/ezagent.socialware.import_remote.ex`, D5 2026-07-18) — RPC into the RUNNING node, full parse → resolve → conformance → governed `publish_or_upgrade` chain, zero bypass | Exists and is the right chokepoint, but its idempotency semantics are `:published / :upgraded / :exists` — i.e. **silent-skip and silent-upgrade are today's defaults**, and there is no authorization or audit distinction for the overwrite path. |
| **Official-site seed** | `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex` (`run_official_site_seed`, deploy-seed SPEC §2/§4) | Same auto-seed pattern; explicitly IN scope — no definition-vs-instance carve-out. |
| **#1642 (zyli, open)** | `.github/scripts/socialware-manifest-release-gate.sh` + per-package `release.yaml` (e.g. `apps/ezagent_web/priv/socialware_seed/hello/release.yaml`) + CI wiring | CI refuses a shipped-manifest change without a release acknowledgement — the "you changed it, say so" gate this spec wires in as the pre-force acknowledgement step. |
| Related sites kept for context | `CcOrchestratorSeed` / `CodexOrchestratorSeed` sandbox files, `mix ezagent.demo.seed_cc_sandbox`, `Home.Migration`, registry `put_new` | The original plan's §2.2 worklist. **No longer this spec's X** — the orchestrator-sandbox file contracts are separate small items; registries stay constitutive (research ⑥.8); `Home.Migration` skip is correct one-shot semantics. |

### 2.1 The contract that must not break

`apps/ezagent_core/test/ezagent/home/socialware_seed_test.exs:34` ("a
pre-existing package dir is NOT overwritten (respects operator edits)") — the
no-silent-clobber half of that contract is PRESERVED and strengthened (default
becomes a loud error instead of a silent skip). The operator-edit-survives
guarantee migrates from "seed silently tiptoes around edits" to "prod is never
auto-seeded at all; only an authorized force can replace an artifact, and the
operator/developer explicitly acknowledges + extracts first."

## 3. Design — retire the auto-writer, govern the one door

### 3.1 The decision (Allen, 2026-07-30)

1. **Data-import is DECOUPLED from deploy.** Deploying a release never writes
   business/socialware artifacts into a production home or store. Prod
   auto-seed (the boot-scan prod leg + the boot file-copy path + plugin
   official-site auto-seed) is **retired**.
2. **ONE governed import mechanism** — the existing `import_remote` lane
   (`ManifestSeed.import_package/2` chain) — is the only way artifacts enter
   any environment, fresh-prod bootstrap and upgrade alike. Bootstrap is not a
   special path: it is the same import run against an empty store (where
   "exists" never trips).
3. **Default = ERROR if the artifact already exists.** No silent skip
   (`:exists`), no silent clobber (`:upgraded`) — both current defaults go. An
   import that meets an existing artifact fails loud and names it.
4. **Explicit `force` = delete-old + overwrite**, permitted only as a
   **cap-authorized, audited** operation. The developer/operator is obligated
   to extract or migrate the old data BEFORE forcing — force is destructive by
   contract, not accidentally.
5. **No definition-vs-instance distinction, no hash reconciliation.** The
   official-site package obeys the same rule. No shipped-hash ledger, no 3-way
   compare, no divergence telemetry lane — the reconcile problem is dissolved,
   not solved.

### 3.2 Structural requirement — force must be impossible to stumble into

Per the standing authz rule (structural, not disciplinary): `force` is NOT a
casual CLI flag whose honesty we trust. The overwrite branch of the import
chokepoint must demand an **un-forgeable witness** — a capability held by the
authorizing identity, checked at the `publish_or_upgrade` chokepoint itself (not
in the mix task), with an audit record (who/what/when/old-artifact identity)
emitted on the same commit. A bare `--force` with no cap must be structurally
incapable of reaching the delete-old branch. Accidental clobber becomes
impossible by construction, exactly like the #1604 ownership fix made
adopt-clobber impossible rather than discouraged.

### 3.3 Convergence with #1642 — the acknowledgement gate

zyli's release gate is the missing "conscious change" half: CI refuses a change
to a shipped package without a `release.yaml` acknowledgement. Wired together:

- **Build time (#1642):** you cannot SHIP a changed artifact without
  acknowledging the change.
- **Import time (this spec):** you cannot LAND an artifact over an existing one
  without an authorized, audited force — having first handled the old data.

Same artifact identity, two ends of the pipeline, no automatic writer between
them. #1642 lands as-is; this spec adds the import-time half and cites the
release acknowledgement as the expected provenance of any force.

### 3.4 What stays (and why it's not scope creep back in)

- **dev/test convenience auto-seed stays**, config-gated exactly as today
  (`socialware_manifest_boot_scan` keeps its dev leg; test stays opted out).
  The retirement is of the **prod** leg only — dev iteration loops are not the
  hazard; unowned prod writers are.
- **#1633's missing-file reconcile stays as-is** — interim runtime auto-heal
  for existing deployments; it becomes moot in prod the moment prod auto-seed
  retires (nothing seeds, so nothing half-seeds). It is not extended to
  changed-file handling (that was the hash-reconcile branch, now dead).
- **Registry `put_new` semantics untouched** (constitutive of the actor model).
- **Flavor-store #1604 ownership fix untouched** (cited as corpus, not work).

### 3.5 Sequencing

- **P1 — govern the door.** `import_package/2` chain: default error-on-exists
  (replacing silent `:exists`/`:upgraded`), `force` branch gated on the
  authorization cap + audit emit (§3.2). Failing-first test: import over an
  existing artifact without force → loud error, store untouched; with cap-less
  force → structurally refused; with authorized force → old deleted, new
  landed, audit row present.
- **P2 — retire prod auto-seed.** Flip `config.exs:38` prod leg off; remove the
  prod boot-path file-copy trigger and the plugin official-site auto-seed
  child; document the fresh-prod bootstrap runbook as "run the import" (same
  door). Existing deployments: one acknowledged import per package during the
  cutover window (operator runbook, not code).
- **P3 — CI wiring.** #1642's gate merged + referenced from the import error
  message ("artifact exists — if you shipped a changed package, see the
  release acknowledgement; to replace, use the authorized force after
  extracting old data"). ARCHITECTURE.md Decision-Log entry: "prod data-import
  is decoupled from deploy; auto-seed is dev/test-only; the governed import's
  exists-default is error; force is cap-authorized + audited."

### 3.6 Acceptance

- P1: the three force-path tests above; `:exists`/`:upgraded` silent paths
  provably unreachable from the import lane (test enumerates outcomes:
  `:published | {:error, :exists} | forced-with-audit`).
- P2: a prod-mode boot on a node with NO seeded artifacts starts clean and
  imports nothing (red today: boot-scan seeds); dev-mode boot still seeds;
  `socialware_seed_test.exs` operator-protection tests stay green or are
  superseded by the stronger error-on-exists tests (never weakened).
- P3: #1642 gate red on an unacknowledged shipped-package change (its own test
  `socialware-manifest-release-gate_test.sh`), green on baseline.

## 4. What this deliberately preserves

- The no-silent-clobber guarantee — strengthened from silent-skip to loud
  error + authorized-only replacement.
- `import_remote`'s governance chain (parse → resolve → conformance →
  `publish_or_upgrade`) — reused verbatim as the single door; only its
  exists/overwrite policy changes.
- Dev iteration ergonomics (dev auto-seed + the D5 RPC import lane).
- #1642's gate as shipped — this spec consumes it, doesn't modify it.

## 5. Open questions (genuinely open post-grill)

1. **Where the force-authorization + audit lives:** which cap authorizes force
   (a workspace-admin cap? a dedicated `socialware.force_import` cap minted to
   operators?), and where the audit record goes (the existing audit writer
   stream vs a dedicated import ledger)? The chokepoint is fixed
   (`publish_or_upgrade`); the cap taxonomy + audit sink are Allen's call.
2. **Dev-vs-prod seed gating shape:** is flipping `config.exs:38` to
   `config_env() == :dev` the whole retirement, or do the `Home.SocialwareSeed`
   boot fallback and the plugin official-site seed children need structural
   removal in prod builds (so the prod release physically contains no
   auto-seed path)? Recommendation: structural — config flags can regress,
   absent code cannot.
3. **"Exists" identity:** does error-on-exists key on package name alone, or
   name + published content identity (byte-identical re-import of the same
   artifact = idempotent `:ok` no-op)? Idempotent-identical would keep
   bootstrap re-runs safe; anything non-identical still errors.
4. **Cutover for live deployments:** the one-time acknowledged import per
   existing package (P2) — operator runbook only, or a `mix` helper that
   enumerates currently-deployed packages against the release set?
5. **Official-site content updates post-retirement:** site content changes now
   arrive via authorized import instead of deploy — confirm the release
   cadence owner for that (who runs the import when hello/官网 content ships).
