# Handoff: cc-custom configurable completion backends — BUILD

> **Date:** 2026-07-17 · **From:** gaga Codex session (clarify-first line) · **To:** an independent developer (human or agent)
> **Tracking:** 2026-07-17 board / `cc-deepseek → cc-custom + DeepSeek/Kimi real proof` · **Base:** `origin/main` @ `66734aae52ce5f39c54ad5f4d34569cf929a6015`
> **Status:** confirmed build handoff — design APPROVED by lead 2026-07-17 (Q1 `[1m]` values, Q2 role-slot provider key, Q3 local live proof); research returned via Draft PR #1449

## 0. Mission

Replace the DeepSeek-specific cc flavors (`cc-deepseek` / `cc-headless-deepseek`)
with **one provider-configurable backend facility per transport** —
`cc-custom` / `cc-headless-custom` — driven by a **closed, server-owned
provider-profile catalog**, and prove **both DeepSeek and Kimi** through the
real cc path (PTY + headless SDK sidecar). No runtime forks, no new
Kind/Behavior, no per-vendor modules: a vendor is one catalog entry.

This handoff stays independent from Git Provider Draft PR #1445: separate
branch, separate PRs, no shared files.

## 1. Required reading (before writing code)

1. Root `AGENTS.md`; skills `ezagent-developer` (invariants gate your PRs),
   `dev-together`, `elixir-phoenix-helper`, `test-driven-development`,
   `verification-before-completion`, `receiving-code-review`.
2. **The approved design:** `docs/superpowers/specs/2026-07-17-cc-custom-backends-design.md`
   — the normative contract (facts, approach scoring, migration parity
   Appendix A/B, resolved Q1–Q3).
3. **The build plan (your task list):** `docs/superpowers/plans/2026-07-17-cc-custom-backends-build.md`
   — 7 PR-sized TDD tasks with complete code. Execute task-by-task
   (superpowers:subagent-driven-development or executing-plans).
4. Current code you will adapt (read before deleting anything):
   `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/provider.ex`,
   `template/cc_deepseek_agent.ex`, `template/cc_headless_deepseek_agent.ex`,
   `plugin_cc/deepseek_bridge_adapter.ex`,
   `plugin_cc/cc_headless_deepseek_bridge_adapter.ex`,
   `test/ezagent/template/cc_deepseek_backend_test.exs`.

## 2. Locked decisions (do not re-litigate)

| # | Decision | Value |
|---|---|---|
| 1 | Architecture | Backend is orthogonal to transport; reuse `CcAgent`/`CcHeadlessAgent` + the single spawn chokepoints; thin shims only for the 1:1 registry |
| 2 | Agent model | role × flavor; no new Kind/Behavior per vendor |
| 3 | Catalog | Closed, server-owned `ProviderCatalog`; template data names a PROFILE only — never an env var/URL/model; unknown profile fails closed (`{:unknown_backend_profile, _}`) |
| 4 | Catalog values | Vendor-doc values of 2026-07-17 (lead Q1): DeepSeek main slots `deepseek-v4-pro[1m]`, Kimi all slots `kimi-k3`; deploy override `:provider_profile_overrides` is the escape hatch |
| 5 | Credential mechanism | Process env only: catalog allowlists the env-var NAME (`DEEPSEEK_API_KEY` / `MOONSHOT_API_KEY`); operator supplies the VALUE (deploy `env_file`, test/CI dummies, local operator injection). No DB store, no files, no rotation in V1 |
| 6 | Secret boundary | Keys never enter template data, snapshots, logs, telemetry, config dirs, transcripts, or status detail strings |
| 7 | Error atoms | `{:backend_api_key_missing, profile}` / `{..., profile, uri}` / `:missing_backend_profile` / `{:unknown_backend_profile, name}` — the old `:deepseek_api_key_missing` is retired (plan T1S5 generalizes the skip match) |
| 8 | Migration | No shims/aliases (C4); deepseek flavors deleted in PR-6; dev DBs wiped + reseeded; live agents destroyed + recreated as `cc-custom` |
| 9 | Socialware definitions | Role-slot maps gain additive optional `provider` key (lead Q2) |
| 10 | Live proof | Local (lead Q3); keys at `~/.ezagent/default/credentials/cc-custom.env` (chmod 600), sourced by proof commands; value never in chat/command text/repo |
| 11 | Boundaries | Do not touch AgentRuntime ARB, EntityCaps/`caps_json`/no-tail, Git Provider C/D, Kanban dispatch; no deploy/merge without lead authorization |

## 3. Architecture primer

- `Provider` (plugin) = the single env-block chokepoint for BOTH transports:
  PTY merges `provider_env/1` into `cmd_env` LAST (`spawn_plan.ex:101-153`);
  headless threads it as the sidecar `:cmd_env` → `EZAGENT_CC_SDK_ENV` → the
  Python worker's SDK `env=` (`cc_headless_agent.ex:274-295`,
  `sdk_sidecar.ex:268`, `ezagent_cc_sdk_worker.py:96,108`). Both chains are
  already provider-neutral — you are changing the DATA source behind them
  (hard-coded deepseek → catalog), not the chains.
- Flavor ↔ template class is 1:1 (reverse lookups in
  `agent_flavor_resolver.ex:129-164`; adapter flavor match in
  `adapter_registry.ex:118-137`) — that is the ONLY reason the new template
  classes/adapters exist; they delegate everything else.
- Cold restart: `respawn_template_data["flavor"]` + non-reserved
  `"provider"` ride the sandbox slice (C3 in spec §3); no secret persists.
- The credential seams are flavor-keyed and become profile-aware in PR-4:
  `CredentialPrecondition.check_source/4`, the spawn-fail→skip match in
  `definition_agents.ex`, and the UI status path via
  `Domain.Agent.read_credential_status/3` (`opts[:backend_profile]`).
- Headless reply routing needs ONE clause per headless flavor in
  `behavior/agent/receive.ex` (else replies fall to curl's global
  `:sync_result` and are dropped).

## 4. Design & phased plan

Design approved 2026-07-17 (spec, Approach 1 of 3 — comparison in spec §3).
Phases = the plan's 7 tasks, each an independently green PR onto
`feat/cc-custom-backends`:

1. **PR-1** `ProviderCatalog` + `Provider` facade generalization (+ skip-atom generalization).
2. **PR-2** `cc-custom` PTY flavor (class, adapter, registration, fail-closed validation).
3. **PR-3** `cc-headless-custom` + `receive.ex` clause.
4. **PR-4** credential-routing profile threading (precondition, definition_agents, recipe_materializer, UI status path).
5. **PR-5** seeds + `config/test.exs` + CI + gitleaks + collateral (AFTER PR-4 — the orchestrator's automatic lane depends on the threading).
6. **PR-6** retire deepseek flavors; full parity (spec Appendix B); grep gate.
7. **PR-7** local live proof: CLI probes (spec §2.4) + product-path transcripts for both vendors + negative proofs; evidence under `docs/e2e/2026-07-17/cc-custom-live-proof/`.

## 5. Definition of Done — build (closed set; reconcile line-by-line at return)

- [ ] `cc_custom.agent` (PTY) + `cc_headless_custom.agent` spawn with
      `provider: "deepseek"` AND `provider: "kimi"` — one facility, both
      vendors, zero vendor-specific modules. Proof: `cc_custom_backend_test.exs`
      + PR-7 transcripts.
- [ ] Fail-closed contract: missing profile → `:missing_backend_profile`;
      unknown → `{:unknown_backend_profile, name}`; missing key →
      `{:backend_api_key_missing, profile}`; automatic lane SKIPS (never
      halts) a key-less role slot. Proof: validation/provider/precondition/
      materialize tests + PR-7 negative proofs.
- [ ] Cold restart re-resolves flavor + profile from `respawn_template_data`;
      no secret in any persisted artifact (grep evidence in PR-6/PR-7).
- [ ] Plain `cc` / `cc-headless` launch env byte-unchanged (no-leak tests).
- [ ] Migration parity: every spec Appendix A row ticked; retired suite's
      coverage survives in `cc_custom_backend_test.exs` (Appendix B); zero
      `cc-deepseek` code references after PR-6 (grep gate).
- [ ] Orchestrator seeds + built-in socialware definition run on
      `cc-custom` + `provider: "deepseek"`; test/CI dummies for both keys.
- [ ] Product evidence: two sanitized success transcripts through the real
      cc path (DeepSeek + Kimi) with profile, model, transport, command,
      timestamp, outcome — `docs/e2e/2026-07-17/cc-custom-live-proof/`.
- [ ] All gates green per PR: focused tests, `mix ezagent.arch.scan`,
      `mix ezagent.doc.scan`, `mix ezagent.uri_query.scan`,
      `mix ezagent.check_invariants`, `mix format --check-formatted`,
      `mix precommit` (PR-6 full suite), `:ezagent_plugin_check`.
- [ ] **CI (`precommit + check_invariants`) green on the PR head + branch
      rebased on `main`** (machine return gate).

## 6. Discuss-first vs deferred

**Clarify-first:** done — this is the build handoff produced by the research line.
**Discuss-first (stop and ask the lead before building):**
- retaining any compatibility alias despite the no-shim rule;
- changing plain `cc` / `cc-headless` semantics (their env path must stay byte-unchanged);
- adding a UI credential store, arbitrary endpoint/model editor, or a third vendor;
- touching deploy data, rotating keys, or running more than the minimal billable probes;
- needing changes outside the plan's file list (esp. beyond plugin_cc + the
  named domain touchpoints `receive.ex`, `definition_agents.ex`,
  `credential_precondition.ex`, `recipe_materializer.ex`, `domain/agent.ex`,
  `definition_registry.ex`).

**Deferred (lead-adjudicated later phases):** arbitrary third-party providers;
user-managed credentials/UI; health monitoring/quotas/failover/model discovery;
de-flaking beyond the first dual-backend proof; Git Provider OAuth/token broker;
`ANTHROPIC_SMALL_FAST_MODEL` (neither vendor documents it); Kimi model tiers
beyond `kimi-k3`.

**Never deferred:** secret non-egress, fail-closed structured errors, migration
parity, gates, PR-head CI, the two real-path transcripts.

## 7. Conflict-avoidance

Owns: `apps/ezagent_plugin_cc` (provider/catalog/templates/adapters/application
+ tests + priv comments), `config/test.exs`, `.github/workflows/ci.yml`,
`.gitleaks.toml`, `scripts/audit_agent_skill_homes.exs`, and the six named
domain touchpoints (§6 list) + `credential_adapter_completeness_test.exs` /
`arch_baseline_manifest.exs`. Must NOT edit: Git Provider Plan C/D specs/code,
`apps/ezagent_domain_git`, Kanban/world runtime, AgentRuntime ARB, EntityCaps,
#1445 artifacts. Coordinate before touching shared global config another
in-flight branch also edits.

## 8. Merge model

PRs merge into the task branch `feat/cc-custom-backends` (never `main`);
keep rebased on `origin/main`; one PR per plan task, in order (PR-5 after
PR-4). The lead owns final review order + merge to `main`. Draft PR #1449
already carries the design record; implementation PRs stack on the same branch.

## 9. Gates, file/LOC estimate, open questions

Gates: spec §6 set per PR (listed in DoD above).
New files: `provider_catalog.ex` (~90 LOC), `cc_custom_agent.ex` (~170),
`cc_headless_custom_agent.ex` (~130), 2 bridge adapters (~45 each),
`provider_catalog_test.exs` (~70), `cc_custom_backend_test.exs` (~450).
Modified: provider.ex (~full rewrite, similar LOC), 6 domain touchpoints
(≤30 LOC each), seeds/config/CI (~40). Net deletion in PR-6 (~−700 LOC).
Open questions: none — Q1–Q3 resolved 2026-07-17 (spec §10). New questions
surfacing mid-build go to the lead per §6.
