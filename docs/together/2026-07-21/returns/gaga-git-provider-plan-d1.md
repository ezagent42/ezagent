# Return: Git Provider V1 — Plan D1 Connection Substrate (acceptance)

> **Date:** 2026-07-21 · **From:** Claude takeover session (continuing the Codex/gaga D1 session) · **To:** Allen + next session
> **Tracking:** Git Provider V1 / Draft PR #1445
> **Branch:** `feat/git-domain-spine`
> **Status:** D1 complete pending push — original plan Tasks 0–9, fence/driver-reconciliation/system-closure amendments, Task 9 verification, dual final reviews, and all review fixes are committed on the branch.

## 1. Scope delivered

The provider-neutral D1 connection substrate, as designed in
`docs/superpowers/specs/2026-07-18-git-provider-v1-d1-connection-substrate-design.md` and amended by
the 2026-07-19 fence amendment, the 2026-07-20 driver-reconciliation amendment, and the
2026-07-20 system-closure amendment:

- `apps/ezagent_domain_provider_connection` (depends only on `ezagent_core` + `ezagent_domain_identity`): five-table Ecto aggregate, closed types, closed transition graph, store with row locks/CAS, driver + backend-pair registries, fail-closed AEAD key ring, local authorization backend, callback ingress, credential replacement/refresh/termination/recovery, exact selector for D2.
- Stateless registry-only `Ezagent.Behavior.ProviderConnection` Lifecycle on the User Kind — the only management command boundary (`entity://<workspace>/user/<owner-id>`); ProviderConnection is not a Kind and has no URI.
- `Ezagent.ActionSet.GitTaskAccess` remains the only Git-operation authority; core gained durable cold-cap verification.
- Secret boundary: no credential/callback code/state/PKCE verifier/key material/provider body in structs, Inspect, logs, telemetry, events, snapshots, Agent homes, task worktrees, audit rows, or error payloads — now enforced by one `EffectBoundary` wrapper plus AST gates.

Explicit non-goals (unchanged): GitHub OAuth endpoints/scopes/token handling, Req/Git Data production adapter, settings UI, Kanban projection, real provider credentials, deployment. D1 implements local authorization correlation only.

## 2. Takeover state (what this session found)

The Codex session stopped mid-Task-9 with: Closure C committed and dual-approved; Task 9 verification mostly green; an arch/doc ratchet regression repair **uncommitted** in the worktree; 54 commits unpushed. This session verified the uncommitted repair (provider suite 284/0, arch 7/7+42/42, doc 404/404), committed it as the structural-boundary commit, then rebased.

## 3. Rebase onto main (mandated by Allen) and the migration yield

Rebased 211 commits onto `origin/main` `5afe9aa31`. Conflict resolutions (all semantic unions or deliberate main-wins, folded into replayed commits):

- `cc_headless_agent.ex`: union — main's F4 `ensure_config_home` wrapper **and** the branch's launch_context `opts` forwarding.
- `mix.exs`: main's `run_cc_sdk_worker_tests/1` alias-function gate supersedes the branch's older cmd-string step.
- curl tests: union — G5 structured ErrorSignal assertions **plus** the branch's `attachments == []` assertion (field verified present).
- `demo_smoke_test.exs`: main's deliberate flake-hardening rewrite (#1491/#1495) wins over the branch's superseded seeded-session membership line.

**Deviation recorded:** main had landed `20260718000000_socialware_mounts_person_scope.exs` while the draft branch held the planned-frozen `20260718000000_create_provider_connections.exs`; Ecto refuses duplicate versions. Following the amendment's own collision-safe-successor precedent, the D1 base migration moved to `20260718001000` — **module and content bytes unchanged** (commit `839bb131f`; both final reviewers re-verified the rename is content-identical), and the upgrade gate records the successor explicitly. Stale D1-era partition databases carrying the old version row were dropped (281).

## 4. Task 9 verification (post-rebase, pre-review)

- Provider-connection suite 284/0 (later 320/0 after review fixes); Git 155/0; Identity 476/0; Core 1082/0; migration upgrade gate 3/0; fresh-DB full migration chain green.
- arch.scan oversized 7/7 + duplicates 42/42; doc.scan 404/404; umbrella compile `--warnings-as-errors`; `git diff --check`.
- Full `mix precommit` run twice (partition `d1pc`): run 1 web 378/4, run 2 web 378/1 — every failure a **different** `EzagentWeb.HomeLiveTest` wizard/redirect case; signatures are full-suite concurrency races (GenServer.call 5 s timeouts under `+S 4:4`; `DBConnection.OwnershipError` in `on_exit` seeding). Focused web suite 378/0 twice; the branch diff touches none of the failing paths; same flake class as main's known #189-tail work. Per the plan's rule (classify only independently reproduced failures) these are recorded, not blocking.
- Codex's earlier Identity 471→1 flake (same class, focused 16/0) and a cc-config-home 5 s dispatch timeout (focused 11/0) recorded the same way.

## 5. Dual final reviews and their fixes

Two independent read-only reviews ran: amendment-range (`55e0c636c..HEAD`) and whole-D1 X-level (`f745b6250..HEAD`). Both returned CHANGES_REQUESTED; **zero Critical**. All findings were fixed in five commits and re-verified (full provider suite 320/0; upgrade gate with new probes; arch/doc gates green):

| Commit | Finding(s) closed |
|---|---|
| `17ca871ad` | **X-level Important** — bare plugin effect calls could leak provider bodies/credential material into logs/error tuples. One `EffectBoundary` wrapper now fences all 16 sites (12 bare wrapped, 4 unified); probes prove payload secrecy; AST gate forbids bare applies. |
| `6ea250a6d` | duplicates ratchet 43>42 — the duplicate lived on **main** itself (hello's `agent_recipe/1` copy); consolidated behind `RecipeAttributes.fetch_or_resolve/1`, healing main's gate too. |
| `2c7c4a50e` | **Amendment Important 1** — superseded prepared refresh never converged, stranding a live provider-minted credential. Generation-only supersession check in `Refresh.recover`; provider-owned rows compensate to `finalized` (discard exactly once), all-NULL rows fence. `20260721000000` extends the ownership CHECKs additively (two refresh-scoped shapes). |
| `54736c619` | **Amendment Important 2 + Minor 3, X-level Minor 3** — callback source matrix now purpose-aware and spec-§4-aligned (`expired` admitted for reauthorize; `refresh_required` rejected), single-owned by `AuthorizationAttempt`; recovery query aligned; `backend_committed` retry drives the idempotent commit with full stable-scope + digest verification. |
| `14930ab1c` | **X-level Minors 1-4, amendment Minors 4-5** — `Transition.mutate` terminal sources fail closed (`:connection_terminal`, no `WithClauseError`); handoff AAD binds the real operation class (`store:`/`replace:`); forward migration `20260721001000` restores the 02000 trigger for `replace` with a class-scoped generation clause (`store` exact, `replace` current-or-past — the terminal-callback-proof race); 02000/04000 sha256-pinned; ABBA lock order documented. |

Re-reviews: amendment-scope APPROVED; X-level APPROVED. (Verdicts finalized in the push note; both re-reviewers confirmed closure per finding.)

## 6. Deferred for design adjudication (Allen sign-off requested)

1. **`provider_connection_events` has zero writers.** Design §5.4's append-only audit projection has schema/constraints/index but no writer anywhere; every D1 transition is unaudited. Adding writers is new behavior surface — not implemented unilaterally.
2. **Selector is `status == "active"` only.** `refresh_required`/`refreshing` connections (whose current credential may still be valid) are invisible to D2 selection. Fail-closed reading is consistent, but design §4/§8 wording is ambiguous — confirm intent before D2 builds on it.
3. **Refreshing wedge (emergent property of approved decisions).** A permanently-failing refresh retries forever at capped backoff (mandated), keeping the connection inside the active-binding unique index — so re-binding the same external account is terminally rejected with `account_conflict`, and revoke/disconnect are Decision-B-fail-closed in D1, leaving no in-D1 unblocking path. Spec-conformant; needs explicit sign-off before the follow-up phase enables these flows.
4. **Runtime config seams** (`:command_boundary`, `:credential_backend_implementations`, `:callback_redirect_pairs`) have no production guard. Stock prod config sets none of them, so D1 is inert/fail-closed in production today (matches the deferral list), but the command-boundary swap is a convention-protected foot-gun.

## 7. Honest boundary

- D1 remains a provider-neutral, in-memory/local-correlation substrate on a Draft PR: no GitHub plugin/transport, no OAuth UI, no PAT path, no real credentials, no deployment, no merge authorization.
- The migration-version yield (§3) is the one planned-frozen constraint we had to break; it is recorded in the upgrade gate and both reviews re-verified content identity.
- Full-suite concurrency flakes (§4) are recorded with repro evidence; none independently reproduce.

## 8. Reproduction

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-domain-spine
# provider domain (uses an isolated partition DB)
MIX_TEST_PARTITION=d1final SHELL=/bin/bash ERL_FLAGS='+S 4:4' MIX_ENV=test \
  mix test apps/ezagent_domain_provider_connection/test
# static gates
mix ezagent.arch.scan && mix ezagent.doc.scan
# review ranges
git log --oneline 55e0c636c..HEAD   # system-closure amendment + fixes
git log --oneline f745b6250..HEAD   # whole D1
```

Key supporting docs: D1 design + three amendment specs under `docs/superpowers/specs/`;
plan under `docs/superpowers/plans/2026-07-18-git-provider-v1-d1-connection-substrate-plan.md`
(amended 07-19/07-20); working notes in `.superpowers/sdd/progress.md`.

## 9. Next

1. Push `feat/git-domain-spine` (fast-forward after rebase; 54+ commits) and refresh PR #1445's body/checklist with §3–§6.
2. Allen adjudication on the §6 list (event writers, selector semantics, refreshing wedge, config seams).
3. D2: provider plugin OAuth endpoints + `Selector`-based active-connection consumption (per the downstream roadmap amendment).
