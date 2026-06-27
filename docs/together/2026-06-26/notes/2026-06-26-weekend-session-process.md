# 2026-06-26 Weekend Session — Process & Efficiency Record

> Per lead: the 0627/0628 weekend work is recorded under the 2026-06-26 cycle.
> Running log of what shipped, the decisions, the regressions (+ root cause), and
> orchestration data, for R&D-efficiency analysis. Append as work continues.

## Outcome
`main` green at `74d7fe19`. ~20 PRs merged. The cycle's major architecture work landed; all flake-masked / parallel-merge regressions found and fixed; lessons recorded.

## Merged PRs (this cycle)
| PR | One-liner |
|----|-----------|
| #1037 | retire customer concept → anon-user + external visibility (read-auth flip token→membership; codex: tightening not widening) |
| #1038 | rename default config key advisor.behavior → agent.soul (+ ConfigKeyRename migration) |
| #1039 | unified non-activating `Domain.Agent.read_*` + `no_surface_read_dispatch` gate |
| #1040 | agent-extension guidance merged into ezagent-developer skill |
| #1041 | #108 partial: loud-fail Loader unmask + ProbeBehavior parity + `mix ci.local` |
| #1042 | minimal CR governance — stage→preview→publish on ConfigStore |
| #1043 | autoservice-v3 reference (capability appendix) |
| #1044 | scenario-13 AutoService tiered e2e acceptance harness |
| #1045 | local ubuntu-CI docker harness (reproduces the macOS-impossible flake) |
| #1046 | F7 PR-A — session.remove_participant (user/invited, isomorphic, owner-gated) |
| #1047 | comms-unify — collapse chat+external onto the :pull adapter substrate (codex-built) |
| #1048 | role-as-data — roles as ConfigObjects, read-through, scriptless guard, `no_role_concept_in_core` gate; RoleRegistry core→domain_agent |
| #1049 | cr-governance follow-ups (WHERE status='open' hardening + non-user-layer test) |
| #1050 | container-reachable chromium sidecar for in-container E2E (browserless, internal-net) |
| #1051 | AutoService Tier-1 seed + deterministic regression (scenario-13) |
| #1052 | fix: positional URI read in role_registry workspace_host (uri_query gate) |
| #1053 | LLM Protocol API rename + endpoint module split (#96, + #99 residual) |
| #1054 | fix: OrchestratorRoleTest sandbox-ownership (DataCase + seed) |
| #1055 | eliminate #108 CI flakes — AgentReadTest read_key + Kind.Server.init resilience + SessionTemplate retry |
| #1056 | fix: autosvc Tier-1 seed RoleRegistry rename (#1051/#1048 parallel-merge regression) |

## SPECs / research produced (pushed branches; some awaiting impl)
unified-non-activating-agent-read · cr-config-governance · role-as-data-cr-governance · unify-comms-on-adapter-substrate (+ plan) · f7-operator-remove-delete-session · recipe-responsibility-split · container-e2e-browser · role-for-users-domain-role (research) · ci-flake-diagnosis · comms-on-external-adapter · docker-deploy-agents-impact · autoservice scenario-13.

## Key architectural decisions (lead)
- **customer → anon-user + external visibility** (business concept out of generic core).
- **advisor vertical deleted; advisor.behavior → agent.soul** (the key was neither advisor nor behavior — it's the agent's soul/recipe).
- **unified non-activating agent-read** + anti-recurrence gate (reads never force-activate cold agents).
- **role = data** (ConfigObject), built-ins seeded idempotently; RoleRegistry relocated core→domain_agent (`Ezagent.Agent.RoleRegistry`) with a `no_role_concept_in_core` gate. OQ-1 = scriptless data-roles (script stays operator/code-only).
- **role is two homonyms**: A = agent *recipe* (what an agent is built from) vs B = *responsibility* (a principal's session role_name + routing). DECISION: split them (recipe vs responsibility), decouple "recipe-name == session role_name". **No `domain.role`** — B's approval/arbiter need (B2) lives in domain_workspace(assignment)+domain_session(workflow) on existing membership+caps+routing; B2 DEFERRED ("team-routing", revisit later).
- **F7 (remove member / delete session)** = a Session-owned, agent/user-**isomorphic** `remove_participant` primitive (owner-gated), NOT an operator-borrows-orchestrator's-cap problem. PR-A = user/invited (membership-only); PR-B = spawned-worker teardown via an owner `{:spawned_by, owner_uri}` destroy cap (exploits existing lineage, no graph change, dead-orchestrator fallback).
- **comms** = chat+external collapse onto one `SessionFeedChannel` over the ExternalMirror `:pull` substrate; abstract callbacks low, concrete adapters high (dep-DAG legal). PR-3 AnonIngress / PR-4 world deferred.
- **trust model**: ezagent stays self-hosted/operator-only → single-container deploy topology is correct; container-per-agent collapses with #112 into one trigger (admitting untrusted authors — not now). agent-browser E2E survives containerization via a remote-CDP chromium sidecar.
- **autoservice-v3** reframed from a feature roadmap into a tiered e2e acceptance scenario (scenario-13).

## Regressions found + fixed (efficiency cost — all flake-masked or parallel-merge)
| Regression | Root cause | Cost | Fix |
|---|---|---|---|
| **AgentReadTest** `KeyError :effective_body` | #1039 single-key `read_key` + #943 cascade-appends-agent.soul → 2 states → match fails. Deterministic, but its NAME was on the flake list → dismissed as flake across ~a dozen merges. | Masked real failures; eroded CI signal | #1055 (`Enum.find` the requested key) |
| **uri_query.scan red** | #1048 relocated `role_registry.ex` carrying a positional `%URI{host/path}` read; uri_query.scan is outside the precommit log I checked → admin-merged unaware | main gate red, undetected until a rebase | #1052 (use `Ezagent.URI.workspace_name!`) |
| **OrchestratorRoleTest** ×12 OwnershipError | #1048 made role lookup a DB read-through; the cc orchestrator-role test still used `ExUnit.Case` (no sandbox checkout/seed); sibling migrated, this file missed | main red | #1054 (DataCase + seed, test-only) |
| **AutoserviceTier1SeedTest** ×2 UndefinedFunctionError | #1051 (parallel) called `Ezagent.RoleRegistry.register/1`; #1048 (parallel) renamed it to `Ezagent.Agent.RoleRegistry.seed_role_if_absent` → module fails to load | main red | #1056 (2-line rename) |

## Orchestration data
- ~30 background subagents dispatched (SPEC / impl / codex-review / investigation). Heavy parallelism; codex adversarial-review gating every meaty PR (#1037/#1038/#1042/#1046/#1047/#1055 etc.).
- **Recurring transient API stall** ("Response stalled mid-stream") hit several long-running subagents (role-as-data ×3, docker-fix ×2, F7-PR-B ×2, comms-gates ×2). Mitigations: instruct **commit-after-every-step** (so a stall loses nothing) + **re-dispatch fresh** when a repeatedly-resumed transcript got too large to resume.
- **Operator-side bug**: a batch queue-merge bash had a var-scoping issue that no-op'd the failure check → 2 PRs merged without real verification (no new damage — they inherited an already-red main — but sloppy).

## Lessons recorded (memory)
- **Verify the FULL gate suite before `--admin`**, not just the precommit log: `arch.scan` + `check_invariants` + `uri_query.scan` + `doc.scan` + touched-app tests (or `mix ci.local`). A clean precommit ≠ a green gate; uri_query.scan and OwnershipError-ordering live outside it.
- **A "known-flake" name is not a free pass.** Deterministic failure (fails every run / reproduces in isolation) = a real regression regardless of the test's name. Rerun in isolation to tell them apart.
- **Parallel PRs touching renamed symbols collide.** When one PR renames/moves a symbol, audit every other in-flight branch that references it.
- **Commit-per-step** is the durable defense against transient API stalls; re-dispatch fresh when a resumed transcript bloats.
- Big relocations (move + rename + behavior change like read-through) are the highest-risk merges — independently run the whole gate, don't trust a self-reported "0 failures".

## Open / deferred (carried forward)
- **F7-PR-B** (spawned-worker teardown cap-model) — in flight.
- **recipe/responsibility split** impl (SPEC done; lead OQs pending: role_name→responsibility_name? EZAGENT_ROLE env? rename PR timing).
- **comms PR-3 (AnonIngress) / PR-4 (world)** — deferred.
- **comms MED gates** (#125) — deferred (kept stalling); MED debt tracked.
- **Dockerfile.dev image build broken** (#124) — exqlite NIF + npm ERESOLVE; blocks dev/E2E image + likely deploy.
- **#110/#111** deploy-flow live promotion + ezagent-deploy skill — deferred.
- **autoservice Tier-1 GAPs** — cc-orchestrator-via-SessionCreator seed variant; live-claude answer layer (#505); SPA vite rebuild.
- **stale worktree/branch cleanup** (#123).
</content>
