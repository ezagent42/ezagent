# Return: orchestrator-session-config

> **Task:** orchestrator-session-config
> **Branch:** `feat/orchestrator-session-config`
> **PR:** none (per explicit task constraint — no PR opened; lead decides after target-branch review)
> **Dev:** Codex (implementation) · return authored by the returning agent
> **returned_at:** 2026-07-13 09:25 +0800
> **deadline:** none — ad-hoc implementation outside a dated team plan
> **deadline_status:** deferred

**Deferred, not incomplete.** Implementation scope and local gates are complete. `deadline_status` is
`deferred` solely because two *machine-return-gate* items are structurally open under the task constraint:
(1) no PR exists → there is no PR-head CI URL/status; (2) the orchestrator/session-create readiness path
requires a post-merge deployment **canary**, and per constraint this work is neither merged to `main` nor
canary-deployed. **No deferred DoD line self-claims READY TO MERGE** — that verdict is the lead's at `close`.

---

## 1. Scope + source-of-truth spec

**Source of truth:** branch `spec/orchestrator-mcp-revision-v4` commit `eec2f82af04b20b6151657b56df51e174334ca23`,
file `docs/specs/2026-07-12-orchestrator-session-config-api-and-surfaces.md` (SPEC v4, direction confirmed
SOUND by codex adversarial review). Verified I1–I8 (§5) and §8a impl-constraint notes against the
implementation on this branch.

Two delivery phases:

- **P1 — durable-binding cold-restart reachability + lifecycle validity** (standalone, merge-first).
  Synchronously **pre-store the real `:orchestrator_uri → session/intent` binding** on the session Kind
  **before** the orchestrator URI is exposed to transport / async socialware install. This is **NOT** a
  repurpose of `:orchestrator_template_uri` into a runtime join key — `:orchestrator_template_uri` stays
  SessionTemplate **Definition DATA** and is **not repurposed into a runtime binding key**. Replaces the
  zero-caller `prestore_planned_orchestrator_uri`; reader keeps the existing reverse scan; the binding
  carries an **epoch**; the reader serves **only epoch-current** bindings; epoch mismatch **re-materializes**;
  repair must **never drop-without-restore** — on definitive failure it leaves a **discoverable fail-loud
  tombstone** on the same `:orchestrator_uri` key.

- **P2 — Session-Config domain API + thin surface projections.** One domain boundary
  `execute(operation, args, authenticated_principal, addressed_session)` owns schema/contract, validation,
  coercion, defaults, canonical context derivation, readiness, admission, dispatch, and error mapping.
  MCP / HTTP / CLI / World are **thin projections** only. Per-op **declarative** target-scope + admission
  (session op → uniform membership; workspace op → workspace/template caps, no session; template-write op →
  template-write cap). Unified `authenticate(credential) → principal` separating authN from authZ; versioned
  **HMAC PAT** (`esr_pat_v<N>_<raw>`, version selects pepper, selector in-token, single indexed digest
  lookup, token-only, HMAC replaces bcrypt). §3.3a rollout/runbook (invalidate old rows, PAT-independent
  re-mint for users, spawn-plan restart re-mint for service agents, deadlock-free order, three rollbacks).
  `kb_*` via extension contract (not in the domain core set). `add_participant` is a URI-only remote-safe
  projection; `import_participant_manifest` is operator/local-only and blocks remote arbitrary `File.read`.

---

## 2. What's done

- **P1 binding lifecycle:** `Ezagent.Session.OrchestratorBinding` struct with `:active | :tombstone` status +
  epoch, epoch-current lookup, epoch-mismatch + tombstone error surfaces; materializer pre-stores the real
  `:orchestrator_uri` before exposure and keeps `:orchestrator_template_uri` as Definition data; reader
  serves only epoch-current bindings and meets a loud tombstone on failure; warm-cache epoch reject/rebuild.
- **P2 domain boundary:** `Ezagent.SessionConfig.execute/…` owning contract → validation → coercion →
  defaults → context derivation → readiness → admission → dispatch → error mapping, with per-op declarative
  scope + admission gates; extension registry (freeze after deterministic assembly, duplicate-name hard
  reject); `kb_*` removed from the domain core catalog and registered via extension.
- **AuthN / PAT:** unified `Ezagent.Authentication.authenticate/1`; versioned HMAC `entity_tokens`
  (`token_digest` + `digest_version`), single indexed digest lookup, token-only (no supplied identity URI);
  PG + SQLite migrations; `docs/runbook/hmac-pat-rollout.md`; self-mint delivery via `pat_delivery.ex`;
  service-agent re-mint on `spawn_plan.ex` restart.
- **Thin projections + participant confinement:** HTTP controller + projection, CLI facade + projection,
  World conversation actions all route through `execute/…`; `add_participant` URI-only; `import_participant_manifest`
  operator/local-only; an `/etc/passwd`-style path input is rejected at validation and never reaches File.read.

---

## 3. P1 / P2 commit topology

Base: `origin/main` @ `720913ad698caffc7091776f6fbc822a038214d8` (local record; **not** re-fetched this
session — see DoD line 15). HEAD `9820a304499226b5065cca77f95369c7391372e2`; ahead 8, behind 0; worktree clean.

| # | SHA | Subject | Phase |
|---|-----|---------|-------|
| 1 | `5772ff574` | docs(plan): stage orchestrator session-config delivery | plan |
| 2 | `c7f8b851e` | fix(orchestrator): persist current binding before exposure | **P1 — standalone-mergeable, first** |
| 3 | `49a1e05f7` | feat(session-config): own executable operation contract | P2 |
| 4 | `f3db73966` | feat(auth): resolve versioned PATs without identity selectors | P2 |
| 5 | `e629f49c8` | feat(session-config): enforce declared admission gates | P2 |
| 6 | `a072f44e9` | fix(session-config): confine participant manifest imports | P2 |
| 7 | `a21e34779` | fix(auth): preserve PAT during failed rotation | P2 |
| 8 | `9820a3044` | feat(session-config): add HTTP and CLI projections | P2 |

`c7f8b851e` (P1) is a self-contained, separately reviewable/mergeable unit; commits 3–8 are P2 substeps.

---

## 4. DoD reconciliation (all 16 lines — closed set, none deleted/merged)

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | P1 sync pre-store of the real `:orchestrator_uri` binding before transport/async exposure | **met** | `materializer.ex:9-51` (`prepare_orchestrator_binding` → `OrchestratorBinding.active/new_epoch`; `:orchestrator_template_uri` stays Definition data, deleted from working copy at `:19-22`); async-window regression in `orchestrator_binding_lifecycle_test.exs` |
| 2 | Binding carries epoch; reader serves current epoch; mismatch re-materializes | **met** | `orchestrator_binding.ex:12-18,27-33,60-98` (epoch + `:active/:tombstone`; `current/1`; `epoch_current` OK vs `:orchestrator_binding_epoch_mismatch`); warm-cache regression `orchestrator_mcp_reregister_test.exs:98` |
| 3 | Repair-skip restores binding; repair-error leaves discoverable fail-loud tombstone | **met** | `materializer.ex:103-109` (`tombstone_orchestrator_binding`); `orchestrator_binding_lifecycle_test.exs` (repair-skip restores; repair-error loud tombstone); `orchestrator_mcp_reregister_test.exs:133` (tombstone discoverable + fails loud) |
| 4 | P1 standalone before P2, separately reviewable/mergeable | **met** | commit `c7f8b851e` isolated ahead of the P2 substeps (topology §3) |
| 5 | Single Session-Config domain `execute/…` boundary owns contract → dispatch | **met** | `session_config.ex`; `execute_test.exs` (12 test/describe blocks: adapter authority, coercion, readiness-before-admission, dispatch, error mapping) |
| 6 | Each op declares scope/admission; session/workspace/template correctly distinguished | **met** | `session_config/admission.ex`, `session_config/catalog.ex`; `catalog_test.exs`, `execute_test.exs` (session membership; workspace partial results; template cap) |
| 7 | Unified credential-only authN; versioned HMAC PAT single indexed lookup | **met** | `authentication.ex`; `entity/token.ex`; `priv/repo_pg/migrations/20260712010000_version_entity_token_digests.exs` + `priv/repo/migrations/20260712010000_version_entity_token_digests.exs` (SQLite) |
| 8 | §3.3a rollout order, agent restart resign, three rollbacks executable | **met** | `docs/runbook/hmac-pat-rollout.md`; `spawn_plan.ex` (service-agent re-mint on restart); legacy-invalidate mix task `ezagent.entity_tokens.invalidate_legacy.ex` |
| 9 | `kb_*` via extension contract, not in core catalog | **met** | `session_config/catalog.ex` + `session_config/extension_registry.ex` (freeze + duplicate-name reject); `catalog_test.exs` |
| 10 | Participant URI-only remote projection separated from local/operator manifest import | **met** | `orchestrator/tools/participants.ex`; `session_config/manifest_import.ex`; `session_config_controller_test.exs:61-77` (`/etc/passwd` → `validation_failed`, never manifest import / File.read) |
| 11 | MCP/HTTP/CLI/World are thin projections | **met** | `session_config_controller.ex` + `session_config_projection.ex`; `session_config_facade.ex`; `world/conversation_actions.ex`; `session_config_controller_test.exs`, `cli/.../session_config_projection_test.exs` |
| 12 | Spec I1–I8 + §8a have impl + test evidence | **met** | see the **I1–I8 mapping table** (§5) and **§8a coverage** (§6) below — NOT asserted as a blanket "all met" |
| 13 | Full local gates + ci.local pass | **met (prior-run evidence, Dev: Codex)** | commands + results in §7; recorded as prior-run, **not** re-executed in this return session |
| 14 | PR-head CI green + CI URL | **deferred** | no PR by explicit task constraint → no PR-head CI URL/status; lead opens PR + obtains CI after target review |
| 15 | Branch verified rebased onto current remote main | **deferred** | local base is `720913ad…`; **not** re-fetched this session — no remote-freshness claim made; lead decides rebase after review |
| 16 | Merged orchestrator/session-create deployed canary | **deferred** | impossible before merge/deploy; lead owns scheduling/acceptance of the cold-restart canary |

**Method friction:** the task keeps the *target branch* for a one-shot lead review, which differs from
dev-together's default machine-return gate (PR-head CI green + rebased on current `main`). The deployed
canary is dev-together's extra post-merge gate for the orchestrator readiness path, outside this pre-merge
local stage. The spec's `orchestrator_template_uri` requirement is "**not repurposed into a runtime binding
key**", NOT a guarantee of textual zero-touch (the materializer still deletes it from the runtime working
copy while preserving it as Definition data). §8a's file:line refs are anchored on pre-work `origin/main`
@720913 and were re-mapped to as-implemented anchors on this branch. Two #108-class seed flakes were
concurrency/environment friction, not stable product regressions (§8). ci.local generates unrelated
`apps/ezagent_web/assets/pnpm-lock.yaml` churn — checked + cleaned; worktree is clean.

---

## 5. I1–I8 mapping table (spec §5, normative)

| Inv | Statement (abbrev) | impl anchor | test anchor |
|-----|--------------------|-------------|-------------|
| **I1** | ONE domain home for the executable contract; each surface projects a declared SUBSET (core + registered extensions), never adds/renames/reshapes | `session_config.ex`; `session_config/catalog.ex`; `session_config/extension_registry.ex` | `catalog_test.exs` (canonical set = core + extensions; projection ⊆ canonical); `execute_test.exs` |
| **I2** | Surfaces authenticate; boundary admits by op's DECLARED scope; gates authorize; no blanket membership gate (B2) | `session_config/admission.ex`; `session_config/catalog.ex` (per-op `{target_scope, admission_gate}`) | `execute_test.exs` (session membership; `list_templates` workspace op admitted w/o session; template-write cap); `catalog_test.exs` |
| **I3** | Multi-gate authz with the caller's principal; no ambient/system substitution; fail-closed at owning gate | `session_config.ex` (readiness→admission→dispatch with authenticated principal); `capability/authorization.ex` | `execute_test.exs` (readiness-before-admission/dispatch; required args before gates) |
| **I4** | `McpRegistry` ≠ authz — registration is a readiness cache; durable snapshot is source of truth; cc/codex authz-equivalent | `plugin_cc/.../orchestrator/mcp_registry.ex`; `mcp_server.ex` | `orchestrator_mcp_reregister_test.exs:175` (ordinary role/member orchestrator rebuild without legacy OTU) |
| **I5** | Register/lookup key parity (P1) — binding read on the exact key written (`:orchestrator_uri`); reader + writer change together | `orchestrator_binding.ex`; `materializer.ex:9-51,84-98` (write + reverse-scan read on `:orchestrator_uri`) | `orchestrator_binding_lifecycle_test.exs`; `orchestrator_mcp_reregister_test.exs:228` (ETS-miss rebuild via `from_orchestrator_uri`) |
| **I6** | Trusted invocation-context boundary (P2) — caller/session/workspace/owner/parent derive from resolved principal + addressed target; no identity URI from request input | `authentication.ex` (principal from credential only); `session_config.ex` (context derivation) | `execute_test.exs` (participant-path / principal-field rejection); `session_config_controller_test.exs` |
| **I7** | Binding lifecycle validity, cold AND warm; absent-binding avoidance is a WRITER invariant (epoch match / re-materialize / loud tombstone; warm-cache evict-or-epoch-stamp) | `orchestrator_binding.ex:60-109` (`current/1`, `matching/2`, `tombstone`); `materializer.ex:46-109` (pre-store; ensure/tombstone; never drop-without-restore) | `orchestrator_binding_lifecycle_test.exs` (async window; repair-skip restores; repair-error loud tombstone); `orchestrator_mcp_reregister_test.exs:98,133,228` (warm-cache epoch reject/rebuild; tombstone discoverable; ETS-miss rebuild) |
| **I8** | No filesystem trust boundary over remote surfaces — no remotely-projectable op reaches host `File.read` on caller input; `ref` URI-constrained; manifest-import operator/local-only | `orchestrator/tools/participants.ex`; `session_config/manifest_import.ex` (operator/local-only + confined root); HTTP does not expose import | `session_config_controller_test.exs:61-77` (`/etc/passwd` `ref` → `validation_failed`, never a file read); `manifest_import_test.exs` |

---

## 6. §8a impl-constraint coverage (spec §8a — non-normative; the code wins)

| §8a note | status | as-implemented evidence |
|----------|--------|--------------------------|
| `entity_tokens` migration must handle `token_hash TEXT NOT NULL` (new mint writes no bcrypt hash) | met | PG + SQLite `20260712010000_version_entity_token_digests.exs` add `token_digest`/`digest_version` and reconcile the legacy NOT-NULL column |
| Password login mints no PAT today — self-mint delivery must be specified | met | `apps/ezagent_web/lib/ezagent_web/pat_delivery.ex` (one-time secure delivery; repeat-login policy); runbook §3.3a |
| Epoch/tombstone storage shape must stay reader-compatible with the bare `%URI{}` readers | met | `orchestrator_binding.ex:38-56` `decode/1` accepts struct, map, **and** bare `%URI{}` (legacy shape) — readers updated in lockstep |
| `list_templates` partial-result semantics preserved (per-kind subset, not all-or-nothing) | met | `session_config/admission.ex` + `orchestrator/tools/templates.ex` keep per-kind template-cap partial results; `execute_test.exs` workspace partial-results case |
| Delete the stale `:orchestrator_uri` → `session_complete?/4` docstring | met | materializer docstrings re-mapped to the new binding flow; stale readiness-coupling docstring removed (materializer refactored, `session_complete?` no longer cited) |
| Extension registry — freeze after deterministic assembly; reject duplicate op names; plugin start-order | met | `session_config/extension_registry.ex` (assemble-once + freeze + duplicate-name hard reject); `catalog_test.exs` freeze + duplicate cases |
| Single capability predicate for BOTH preflight AND runtime gate (no authz drift) | met | `session_config/readiness.ex` + `session_config/admission.ex` route through the same predicate as `capability/authorization.ex` runtime gate; preflight refuses before side effects |
| Version the PAT digest format + durable pepper provisioning/rotation/rollback | met | `entity/token.ex` (`digest_version` + HMAC); `authentication.ex` pepper resolution (fail-closed if absent); runbook rotation/rollback |

---

## 7. Local gate results

**Provenance:** the heavy ExUnit suites and `ci.local` numbers below are **prior-run evidence supplied by the
implementation dev (Codex)** on the final committed tree — they were **NOT re-executed in this return
session**. This return session verified, read-only against HEAD `9820a3044`: git topology, proof-path
existence, spec I1–I8/§8a content, and grep-level code anchors (cited in §4–§6). This is deliberately **not**
a PR-CI substitute (see DoD 14).

Focused tests — total **91/0**:
- identity **15/0**, domain session **51/0**, world **14/0**, web **6/0**, CLI **5/0**.

Static / invariant gates — all exit **0**:
`mix format --check-formatted` · `mix ezagent.check_invariants` · `mix ezagent.arch.scan` ·
`mix ezagent.doc.scan` · `mix ezagent.uri_query.scan` · `mix ezagent.check_invariants.lifecycle`.

Full local CI:
`MIX_ENV=test MIX_TEST_PARTITION=scapi ERL_FLAGS='+S 1:1' mix ci.local` → final committed-tree run **exit 0**;
core **1986/0**, domain session **1017/0**, web **339/0**, CLI **37/0**; socialware conformance
chat/orchestrator/socialware each 15 assertions, 3 defs OK.

Flake note: earlier higher-concurrency runs hit two distinct #108-class seed flakes; each isolated re-run
passed; low-scheduler-concurrency full runs then completed clean; the final committed-tree run had no seed
flake. No product code was changed for the flakes. `ci.local` produced unrelated
`apps/ezagent_web/assets/pnpm-lock.yaml` churn, since cleaned — the worktree is clean this session.

---

## 8. Machine return gate status

| Gate item | Status |
|-----------|--------|
| Full local static-gate set + `ci.local` | complete (prior-run evidence, Dev: Codex — §7) |
| PR-head CI (`precommit + check_invariants`) green + CI URL | **deferred** — no PR by explicit task constraint (DoD 14) |
| Branch rebased on current remote `main` | **deferred** — local base `720913ad…`; not re-fetched; no remote-freshness claim (DoD 15) |
| Merged orchestrator/session-create canary实测 | **deferred** — requires merge + deploy; lead owns scheduling (DoD 16) |

Per dev-together's `return.md` machine gate, "gates green" as a prose claim is not accepted as a PR-CI
substitute; the three deferred items above are the exact gap the lead closes after the target-branch review.

---

## 9. Deferred / open decisions for the lead

1. Review `feat/orchestrator-session-config` as a target branch first (one-shot complete review).
2. Accept P1 commit `c7f8b851e` as an independent merge unit?
3. Lead decides rebase / fix / push / open-PR after the review.
4. Obtain the PR-head CI URL + status once a PR exists (DoD 14).
5. Verify remote-`main` freshness / rebase and schedule the orchestrator cold-restart **canary** after
   merge + deploy (DoD 15, 16).
6. Do **not** mark READY TO MERGE or claim prod fixed until those deferred items close.

---

## 10. Method friction (for the lead to promote in `review`)

- The task pins the *target branch* for a one-shot lead review — divergent from dev-together's default
  "PR-head CI green + current-main rebase" machine gate. This is a legitimate pre-merge local stage, not a
  gap; it just means DoD 14/15/16 are lead-owned rather than dev-satisfiable at `return`.
- The deployed **canary** is dev-together's extra post-merge gate for the orchestrator readiness path — it
  cannot be exercised before merge + deploy, so it is deferred by construction, not by omission.
- Two #108-class seed flakes were concurrency/environment friction; isolated re-runs + low-concurrency full
  runs passed; no stable product regression; no product code changed to make logs green.
- `ci.local` emits unrelated `pnpm-lock.yaml` churn — must be checked + cleaned before every return.
- The spec's `orchestrator_template_uri` constraint is "**not repurposed into a runtime binding key**", NOT
  a textual zero-touch guarantee — the materializer legitimately deletes it from the runtime working copy
  while preserving it as Definition data.
- §8a's file:line anchors are on pre-work `origin/main` @720913 (the code says "the code wins"); they were
  re-mapped to as-implemented anchors on this branch before citing.

---

## 11. Merge / request to the lead

请 lead 对本地 target branch `feat/orchestrator-session-config` 做一次性完整审阅。实现范围和本地 gates 已完成；按任务约束，本 return 不执行 rebase、push、PR 或 main merge。PR-head CI、远端 main freshness 和 merge-after-deploy canary 保持为 lead open decisions。
