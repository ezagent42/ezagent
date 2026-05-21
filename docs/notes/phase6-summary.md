# Phase 6 — Summary

**Status**: closeout PR landing.
**Branch tag**: `phase6` (created at PR 12 merge).
**Duration**: 2026-05-15 → 2026-05-17.

## North-star achieved

> "future devs work on different plugins without coordination"

The three-layer model (core / domain / plugin) makes this concrete:

- **core** owns *mechanisms* — nothing in core knows what Sessions or Workspaces or Feishu chats are.
- **domain** owns *canonical biz primitives* — Chat / Identity / Workspace / UI / Python contract. Owned by the core team; plugins build on them.
- **plugin** owns *adapters* — ezagent (default admin LV), cc_channel (CC v2 host), cc_pty (PTY), feishu (Lark adapter), echo (demo).

## Apps after Phase 6

```
apps/
  ezagent_core/                          ← mechanisms
  ezagent_domain_chat/                   ← Chat behavior, Session/Agent Kinds
  ezagent_domain_identity/               ← User Kind, Identity Behavior, bcrypt
  ezagent_domain_workspace/              ← Workspace Kind/Behavior/Loader/Store
  ezagent_domain_ui/                     ← shadcn-like HEEx primitives
  ezagent_domain_python/                 ← Python plugin contract (placeholder)
  esr_plugin_ezagent/                ← default admin LV pages (was ezagent_web_liveview)
  ezagent_plugin_cc/             ← CC channel registry + tokens
  ezagent_plugin_cc/                 ← PTY-managed claude processes
  ezagent_plugin_cc_bridge_v1_prototype/ ← legacy (still wired; v2 cut-over deferred)
  ezagent_plugin_feishu/                 ← Feishu/Lark adapter
  ezagent_plugin_echo/                   ← demo plugin
  ezagent_web/                           ← Phoenix endpoint / router / controllers
  ezagent_cli/                           ← `mix esr` CLI (RPC to runtime BEAM)
```

## What changed

| PR | Scope | What it bought |
|----|-------|----------------|
| 1 | EZAGENT_HOME DB migration | Dev SQLite leaves the repo working tree (`mix ezagent.home.adopt_db`). |
| 2 | Domain extraction | Three new apps from chat plugin + identity/workspace slices of core. Bcrypt + DataCase relocated. |
| 3 | LV extraction + shadcn-like | `esr_plugin_ezagent` replaces `ezagent_web_liveview`. `EzagentDomainUi.Components` library lands (button/card/badge/page_header/stat). Layer-purity invariant test. |
| 5 | `applies_to_users` | Per-rule sender filter — same matcher, different receivers per user, without scheme bloat. |
| 11 | Domain.Python placeholder | JSON-RPC stdio contract for the future Python plugin ecosystem. |
| 12 | Closeout | Phase 5 regression invariant test, this doc, ROADMAP update. |

## What deferred to Phase 7+

These items were in the original SPEC v2 but pushed out for scope:

| PR# | Scope | Why deferred |
|-----|-------|--------------|
| 4 | CC channel v2 (Phoenix.Channel WS) + delete v1_prototype | Largest single PR — full Socket + Channel + CapBAC handshake + cut-over of Chat.invoke(:receive) for Agent. Best done as its own focused phase or paired-down sub-spec. v1_prototype still works in the meantime; layer-purity exemption notes this. |
| 6 | Feishu user cap-grant UI | Needs PR 7 (CLI per-user token / bearer auth) to land first; depends on per-user identity surface. |
| 7 | CLI per-user token + bearer auth | Moderate scope; CLI currently uses distributed Erlang cookie which is single-tenant. Per-user mode is an explicit security-model PR. |
| 8 | Workspace-scoped routing + multi-Feishu-app | Touches Resolver scoping + Feishu adapter; reasonable to ship after PR 4 cuts over CC. |
| 9 | Canonical auto-derived JSON API | Foundation for PR 10. |
| 10 | Domain.UI auto-derive list/detail/edit pages | Builds on PR 9. |

These move into a Phase 7 SPEC.

## Invariant tests (the closeout gates)

- `apps/ezagent_core/test/invariants/receiver_kind_pattern_test.exs` — Plan B drift defense (Phase 5).
- `apps/ezagent_core/test/invariants/repo_root_clean_test.exs` — Phase 6 PR 1.
- `apps/ezagent_core/test/invariants/layer_purity_test.exs` — Phase 6 PR 3.
- `apps/ezagent_core/test/invariants/phase5_no_regression_test.exs` — Phase 6 PR 12.

## Demo

After PR 12 merges, run:

```
mix ezagent.home.adopt_db       # one-time migration (idempotent if already done)
mix phx.server              # boots at http://0.0.0.0:10042 (tailnet: 100.64.0.27:10042)
```

Then via browser:
1. `/admin/workspaces` — observe the shadcn-styled Workspaces page (card + badge primitives).
2. `/admin/routing` — observe MentionRouting / SessionRouting rules editor still works.
3. `/admin` — existing chat surface (legacy styling for now, scope of incremental migration).
4. (Optional) Feishu / CC channel handshake — unchanged from Phase 5.

Demo script for video: open agent-browser, screenshot `/admin/workspaces` to show shadcn-style cards, then screenshot `/admin/routing` to confirm functional parity with Phase 5.

## Decision provenance

All Phase 6 decisions land in `docs/phase-specs/phase6/SPEC.md` (locked v2). Brainstorm history: 7+ rounds documented in that file. Memory entries added for `feedback_phase_planning_reads_main_docs` and `feedback_plugin_external_integration_is_receiver_kind` during Phase 5; both stay valid.
