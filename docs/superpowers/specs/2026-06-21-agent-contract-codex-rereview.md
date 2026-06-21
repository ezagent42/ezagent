# Codex re-review (round 2) — agent-contract specs (2026-06-21)

Reviewer: `codex exec` read-only, grounded against `main`. Verifies round-1 fixes + hunts new issues.

## Round-1 findings status
| # | Status | Note (file:line evidence) |
|---|---|---|
| P1-1 ctx.caps | **RESOLVED** | `ctx.caps=[]` + `holds_cap?` is the right fix; runtime checks ctx.caps first (`runtime.ex:395-409,539-550`). |
| P1-2 join provisioning | **PARTIAL** | participation grants are session-scoped ✓, BUT `provision_join_authority/2` currently **denies a newly-invited non-member user** — the existing-URI invite path is not provisionable as written (`membership.ex:283-303,341-360,507-523`, `tools.ex:318-323`). |
| P1-3 fallback residue | **NOT-RESOLVED** | `spawn_from_template_content/4` writes **`AgentFlavorAttributes` BEFORE instantiate with no rollback** (`template_spawn.ex:242-246`, `kind/template.ex:296-298`, `agent_flavor_attributes.ex:28-33,75-80`). A failed cc candidate leaves last-candidate flavor state for the codex attempt → not "zero residue". |
| P1-4 version pin | **PARTIAL** | immutable `@hash` pin + deleted-API cleanup correct ✓, BUT `create_session/3` does **not** resolve a tag through `TemplateTags` — it finds an arbitrary matching hash from live/snapshots; the tag API is **unused** (`session_creator.ex:333-345`, `template_resolver.ex:145-160`, `template_tags.ex:154-162`). The "resolve tag→hash at create" claim is aspirational. |
| P2-5 migration ledger | **RESOLVED** | ledger sound; spec correctly flags AgentTemplate is not content-hash-versioned today; working-copy is a durable map (`agent_template.ex:27-31`, `config_actions.ex:23-58,125-148`). |
| P2-6 Role split | **PARTIAL** | spec-1 correct, BUT the **master doc still says `Ezagent.Role` retires** (`agent-definition-contract-design.md:100,268`) — contradiction; Role is live in bootstrap (`orchestrator_role.ex:35-53,117-120`, `orchestrator_bootstrap.ex:61-83`). |
| P2-7 curl tools | **RESOLVED** | fail-compile/degraded matches P18; only clean a stale "tools silently inert" risk line (`spec2:123`). |

## NEW finding
- **[P1] `flavor.compile` boundary not implementable as written.** Today `AgentTemplate.to_template_data/2` **builds AND VALIDATES** final Template-Class data **before** `instantiate/3`; cc/codex `instantiate` then materialize a **`config_dir` reference**, not an in-memory rendered `CLAUDE.md`/MCP map. "Pure `compile` inside `instantiate`" bypasses the existing validation seam and lacks a defined **writer** for derived config. (`agent_template.ex:235-280`, `cc_agent.ex:238-265`, `cc_agent/spawn.ex:143-154`, `home_runtime.ex:178-190,239-268`.) **Fix:** define the exact boundary — either `compile` runs **before** validation and returns final Template-Class data/layers, OR `instantiate`/`HomeRuntime` gain an explicit derived-config materialization contract.

## Verdict (codex)
Not ready. Remaining blockers: (1) participant invite provisioning for new non-member humans; (2) fallback cleanup must cover ALL fixed-URI residue incl. `AgentFlavorAttributes`, AND the `flavor.compile` boundary must be specified against the real `to_template_data`/`instantiate`/config-materialization seam; (3) make tag→hash adoption real in `create_session/3` or drop the claim; (4) fix the master Role contradiction; (5) clean the stale curl risk line.
