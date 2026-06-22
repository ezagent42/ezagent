# dev-together plan — 2026-06-22

_tasks · scope · owned surfaces/files · per-task branch · cross-task conflict map · handoff order_

## Active tasks

| # | Task | Branch | Dev | Status |
|---|------|--------|-----|--------|
| 1 | protocol-api P0 | `external-adapter` | Claude | 🔨 in progress |

**Scope:** New plugin `ezagent_plugin_protocol_api` — `POST /v1/chat/completions` (OpenAI-compatible inbound).

**Handoff:** `docs/superpowers/handoffs/2026-06-22-external-adapter-openai-anthropic-api-handoff.md`
**Spec:** `docs/superpowers/specs/2026-06-22-protocol-api-design.md`
**Plan:** `docs/superpowers/plans/2026-06-22-protocol-api-p0.md` (9 tasks)

**Surfaces owned:** 
- New: `apps/ezagent_plugin_protocol_api/` (entire plugin)
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex` (one forward line)
- Modify: `mix.exs` (one release entry)
- Modify: `apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex` (one sanctioned file)
- Modify: `apps/ezagent_domain_agent/lib/ezagent/behavior/curl_agent.ex` (ref_id fix)

**Conflict map:** No overlap with other active tasks. Router change is a single additive line. Root mix.exs is additive.
