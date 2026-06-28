# Handoff — socialware unification P1–P10 (codex)

**To:** codex  ·  **From:** coordinator (Claude)  ·  **Date:** 2026-06-28
**SPEC:** `docs/together/2026-06-26/specs/socialware-unification.md` (this branch, `docs/socialware-app-unification`, tip `d075a7f7`) — **read it first, it is authoritative.** This handoff is the *execution* layer over it.

## Mission
Implement **P1–P10** of the socialware unification, in the SPEC's recommended order, on **ONE target branch** off `origin/main`. Run the **P10 automated E2E gate** until green. Then **stop and hand the target branch back** to the coordinator for acceptance + merge. **Do NOT self-merge. Do NOT open a PR for review** — the coordinator merges.

## Skills to load (required)
`Skill: ezagent-developer`, `Skill: ezagent-socialware`, `Skill: elixir-phoenix-helper`. Elixir umbrella work — skip none.

## Target branch + workflow
- Create `implement/socialware-unification-p1-p10` off `origin/main` (fresh `git fetch origin` first).
- **Commit per phase** (one logical commit per Pn; if a phase is big, a few commits tagged `[Pn]`). Push incrementally so work is durable against transient API stalls.
- After each phase, run that phase's **verification gate** (column 3 of the phase table in the SPEC §7) BEFORE moving on. If a gate is red, fix it before proceeding.
- The full gate suite per phase (where Elixir is touched): `mix compile --warnings-as-errors` → `mix ezagent.arch.scan` → `mix ezagent.check_invariants` (+ `.lifecycle`) → `mix ezagent.uri_query.scan` → `mix ezagent.doc.scan` → the touched app's `mix test`. **Run `mix ci.local` if it chains these** — but verify `uri_query.scan` + `arch.scan` + `check_invariants` separately regardless (a clean precommit ≠ a green gate).
- **Known flakes — do NOT chase:** `PluginIsolationWorkspaceTest`, `AnonUserGC`, `PresenceReadReceipts`, `WorldHostRouting`, `AgentReadTest`, `DefaultSessionTemplateSeed`. If one of these is the ONLY red, note it and proceed. **Any OTHER failure = real = fix it.** (A "known-flake" name is not a free pass; if it fails deterministically/every-run, treat it as real.)
- `MIX_TEST_PARTITION` if you run parallel suites (umbrella isolation). Prefer sequential for the structural phases.

## Phase order + gates (from SPEC §7)
1. **P0** — concepts/definition doc (SPEC §0 lifted to `docs/`). Gate: doc exists; base/socialware/fixture taxonomy matches code.
2. **P1** — C1 rename `:operator_only`→`:internal` (persisted-data UPDATE; **no DB enum constraint** — verify) + migrate existing data + extend the `no_customer_concept` invariant to forbid `:operator_only`. **Pre-prod, do early.** Gate: invariant forbids `:operator_only`; `mix test` 0 new failures.
3. **P2** — AnonIngress: `Ezagent.Socialware.AnonAdmission.admit_anonymous_participant/2` domain primitive (socialware domain, NOT session — DAG-forced; socialware→session one-directional) + thin web shim `EzagentWeb.Socialware.AnonIngress` (cookie/HTTP only). Collapse the +8 duplicated anon-lifecycle groups. Gates: INV-1 (join cap #154-clean, no `system://`) + INV-2 (mount best-effort, mint/spawn/join fail-closed) + INV-2a (reuse-path spawn failure falls through to mint-fresh) green.
4. **P3** — de-hardcode the behavior-set selection → the SessionTemplate `installs: [{socialware-ref, seed-config}]` composition field; ship a **temporary built-in catalog** so P3 is self-contained (no hard dep on P4). Gates: a `"socialware"` template boots Turn/Surface via DATA, not the 2 call-sites (`session_creator.ex:338,430`, `hello/app.ex:35`).
5. **P4** — the socialware definition object (`config://<ws>/socialware/<name>` — a ConfigObject, sibling of `%Role{}` on the same ConfigStore via a sibling `"socialware"` resolver; **NOT a Kind, NO `socialware://` scheme** — avoids #11) + the install relation (per-install ConfigObject: subject=session, key=socialware-ref; behavior union via `effective_set` `extra_part`) + **SPLIT `public_view`**: identity→install-relation, anon-gate→surface-base attribute. Delete P3's temp catalog. Gate: no `public_view` read anywhere (the 10-site + non-prod parity audit in SPEC §2.3 — all sites re-pointed).
6. **P5** — extract socialware config OUT of SessionTemplate (members/routing_rules/prompt_templates/legends/orchestrator_template_uri move to the socialware-def; template keeps name/description/lineage + `installs`) + re-target the orchestrator tool catalog (`add_managed_member`/`define_rule_set_rule`/`update_template`) to mutate the socialware-def + `migrate_session` for all orchestrated sessions. Gate: tools mutate the socialware-def and round-trip.
7. **P6** — C2 `publish_policy` (`:auto` | `:supervised`) in `visibility_policy`. Gate: `:supervised` holds `:internal` until `:settle`; `:auto` publishes immediately.
8. **P8a** — cap-gate the unfiltered `/sessions` management read (`read_unfiltered`, fail-closed, re-checked per read). **THIS IS THE SECURITY FIX — do it BEFORE P7; do not defer past any unfiltered operator read.** Gate: a non-holder's `recent_in_session/2` excludes `:internal` (would-be leak closed). **No named "operator"/"supervisor" role here** — just the cap bundle (unfiltered-read + `:claim`/`:settle`/`:approve` + `:send`).
9. **P7** — dual-path FORM editor: the world form fills the FULL socialware-def (team/routing/persona/legends + adapter(s) + `installs`); the orchestrator conversation loop edits the SAME definition data; one validation in a domain function both call. Gate: form authors a complete runnable socialware; both paths mutate one source of truth; `"current"` tag auto-published on save.
10. **P8b** — relabel `Surface.operator_tree` / "Operator SessionView" → internal (ride the #1059 deferred Role→Recipe rename window). Relabel-only. Gate: no `operator` name leak.
11. **P9** — `supervisor` named responsibility (ONLY here — routing fan-out + multi-holder pool need a named target) + B2: (a) assignment → `domain_workspace` (`:assign_role`); (b) approval + quorum + arbiter workflow → `domain_session`; (c) fan-out → core routing seam with **INJECTED resolver** (core has no umbrella deps — inject, don't hard-ref); (d) takeover UI/CLI. B1 (per-session single-holder `role_name` + `{:role,name}` routing) exists; B2 is the new multi-holder pool. **NO new `domain.role` app.** Per-sub-step gates in SPEC §7.1.
12. **P10** — the codex-runnable lifecycle E2E suite (completion gate). **P10.0 prerequisite = implement codex-orchestrator** (see below). Gate: the automated suite is green across author→install→customer→supervisor→security→publish_policy.

## P10.0 — implement codex-orchestrator (do this before P10's E2E assertions)
- **Mirror cc's `OrchestratorRole`** (`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/orchestrator_role.ex` — flavor-agnostic recipe, `@skill_ref "ezagent-session-orchestrator"`, registered `"orchestrator"`) onto the codex flavor + a `codex_orchestrator_seed` (mirror `cc_orchestrator_seed.ex`).
- **REUSE the shared/flavor-blind substrate — do NOT duplicate:** executor `SessionManager.run_tool_op(:kb_query, …)` + bridge-token `AgentBridge.TokenStore.verify_token/2`. Wire codex's sidecar tool-loop onto the same `{:run_tool, bridge_token}` forwarding seam cc uses.
- codex bridge infra ALREADY exists: `apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/bridge_adapter.ex` (`@behaviour Ezagent.AgentBridge.Adapter`, flavor `"codex"`, `:subprocess_ws`), `bridge_sidecar.ex`, `app_server.ex`, `codex_agent.ex`, `codex_remote_agent.ex`, `codex_remote_bridge_adapter.ex`.
- codex auth per-agent via `CODEX_HOME` (`codex_agent.ex` `CredentialAdapter`: `credential_env_var "CODEX_HOME"`, `credential_relpaths ["auth.json","config.toml"]`).
- **Anti-scope (OQ-1=(a) holds):** NO new `Behavior.Orchestrator`, NO `Behavior.Template` refit, NO cc PTY path. The orchestrator base = recipe + `Orchestrator.Tools` + `SessionManager` (existing combo).

## P10 E2E suite (the completion gate — must be codex-runnable + green)
Sibling of `apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs`. **In-process dispatch** via `EzagentCli.Exec.exec/1` / `Ezagent.Invocation.dispatch/1` (NOT `mix ezagent` — that's a `:rpc.call` shell needing a running runtime). No browser, no live cc PTY. Asserts via in-process dispatch + **MessageStore landing**, NOT codex stdout.
- (1) Author via dual-path editor → same content-addressed `config://<ws>/socialware/<name>@<hash>` ConfigObject.
- (2) Install → per-install ConfigObject + `effective_set` `extra_part` includes bases+shape.
- (3) Customer-side: AnonIngress mints anon → bare message routes to `bot` (B1 `{:role,"bot"}`) → **codex-orchestrator** picks it up via its tool-loop → calls `kb_query` via the shared seam → **real LLM-woven reply lands in MessageStore**.
- (4) Supervisor-side: `read_unfiltered` holder sees `:internal`; `:claim`/`:settle`/`:approve` flip turn/surface; if P9 done, B2 pool fan-out + quorum + arbiter escalation + stale-holder rejection.
- (5) Security: non-holder's `recent_in_session/2` EXCLUDES `:internal` (fail-closed; asserts P8a).
- (6) publish_policy: `:supervised` holds `:internal` until `:settle`; `:auto` publishes immediately.
- **Anti-stub rule:** assertions observe state produced by PUBLIC author/install/dispatch entrypoints — NEVER hand-insert `ConfigObject`/`:kind_base` stubs. The deterministic test-mode codex stub (sibling of `apps/ezagent_plugin_cc/test/fixtures/fake_orchestrator_claude.py`) is the GATE (exercises real recipe+seed+tool-catalog+bridge-token+kb_query wiring; only final token generation canned) — NOT a hand-stub. Self-minted test `auth.json` + network-allowed env = SECONDARY real-LLM confirmation.
- **The invariant FAILS if any phase is missing/broken** (e.g. absent P8a ⇒ `recent_in_session/2` leaks `:internal` ⇒ assertion 5 fails; absent P4 install ⇒ assertion 2 fails; absent P10.0 ⇒ assertion 3 only echoes, no real LLM-woven reply).

## Credentials — self-generate, NEVER ask Allen
Bootstrap admin token + `set_password`, or mint temp users, from the running system. For codex test creds: the deterministic stub needs NONE; the secondary real-LLM run self-mints `auth.json`. Do not request passwords/tokens from the lead.

## Hand-back (when done)
1. Push `implement/socialware-unification-p1-p10`.
2. Report to the coordinator: branch name + a phase-by-phase commit summary + the **P10 E2E result** (the gate run output — which assertions passed) + any phase where you deviated from the SPEC and why + any residual known-flake-only reds.
3. **STOP.** Do not merge, do not open a PR. The coordinator accepts + merges.

## If you stall mid-stream (transient API)
Commit-before-every-step protects you. If a resume bloats, the coordinator will re-dispatch fresh against your pushed commits.
