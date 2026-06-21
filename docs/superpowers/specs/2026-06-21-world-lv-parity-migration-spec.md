# World ↔ LiveView Parity Migration — Design Spec

**Date:** 2026-06-21
**Branch:** `world`
**Owner:** Claude (codex is on anon-user)
**Status:** DRAFT — awaiting Allen review

## Goal

`ezagent_plugin_world` (React/shadcn islands on a LiveView SSR shell) must fully
**absorb every user-facing feature of `ezagent_plugin_liveview`**. When `world`
merges to `main`, `ezagent_plugin_liveview` is **retired** (app deleted, router
scope removed). Completion criterion is **parity with LV**, not a hand-listed
page set (see lesson `feedback_replacement_task_gate_is_parity_audit`).

## Architecture (unchanged from existing world)

- LiveView (`WorldLive`) = SSR/comms shell only: auth (`:require_entity`),
  routing, the `WorldRenderer` phx-hook, and `Invocation.dispatch/1` for every
  mutation. No business logic in world.
- React/shadcn owns all rendering; calls the **same domain dispatch actions** LV
  calls (chat.send, session.join, member invite, etc.). Business logic stays in
  the domain plugins (im/session/socialware/pty) — untouched.
- `ezagent_domain_ui` (shared atom layer) is consumed by both and **survives**.

## Parity map (LV surface → world status)

✅ = present & real in world · 🟥 = MISSING (this migration)

| LV surface | world status |
|---|---|
| Identities: users/agents list, caps, api-keys, extensions, new, detail | ✅ |
| PTY terminal (pty_input/resize) | ✅ |
| Workspaces list + detail | ✅ |
| Plugins: feishu bindings, auto-derive | ✅ |
| Profile | ✅ |
| Admin: dashboard, observability, registry, snapshots, templates, caps, authz-audit, settings, routing, external-mirror | ✅ (real data) |
| **Session conversation page** (`AdminLive`) | 🟥 — world `/sessions` is only a list table |
| credential_cascade_ui (#17) | 🟥 |
| command_palette (cmdk nav) | 🟥 (primitive exists, not wired) |

### Session conversation page — full feature set (from `AdminLive` + `admin/*`)

Every `handle_event` to reproduce: `chat_compose` (send) + `validate_compose` +
`cancel_upload` (file upload) · inline `@mention` autocomplete · message stream
(`load_older_messages`, `mark_displayed`) · `create_session` · `switch_session`
· `invite_member` + `open/close_invite_modal` · members panel + presence
(online/offline) · `restart_orchestrator` · `routing_rule_add_session` +
`routing_rule_toggle` (per-session mention routing) · `switch_view` +
`switch_to_pty_for_agent` (chat ↔ PTY view switch) · `toggle_debug_panel` ·
`toggle_expand`.

## PR sequence (build world surfaces FIRST, cut over LAST — nothing breaks mid-flight)

- **PR-1 — Session conversation core:** React `Conversation` component + message
  stream (read via dispatch) + composer (send via `chat.send` dispatch) +
  switch_session. world route `/sessions/:id` (detail) + state builder. Gate:
  agent-browser send-a-message E2E.
- **PR-2 — Mentions + file upload:** inline `@mention` autocomplete (member
  options) + file upload/cancel in composer. Gate: E2E @mention + attach.
- **PR-3 — Members + invite:** members panel (list + presence) + invite modal
  (`invite_member`). Gate: E2E invite a member.
- **PR-4 — Session lifecycle:** create_session form + restart_orchestrator +
  per-session routing rules (add/toggle) + view-switch (chat ↔ PTY). Gate: E2E
  create session + restart.
- **PR-5 — credential_cascade_ui** (#17 cascade config) as a world component.
- **PR-6 — command_palette wiring:** wire the existing primitive to
  `CommandSource`/command routes for cmdk nav.
- **PR-7 — Cutover + retire LV:** repoint the `ezagent_web` router (remove the
  `EzagentPluginLiveview` scope; world host owns all routes) + `live_auth.ex:21`
  + migrate the `gettext` backend (world owns its i18n or shares
  `ezagent_domain_ui`) + **delete the `ezagent_plugin_liveview` app** + drop its
  `ezagent_web` dep. Gate: full umbrella compile+test green with LV app removed;
  the parity gate (below) green.

## Parity gate (the completion test)

A new arch/invariant test enumerates LV's user-facing surfaces (route list +
`handle_event` set) and asserts world covers each — fails when world lacks a
feature LV has. This is the gate that would have caught the original gap. It is
removed/becomes trivial only at PR-7 when LV is deleted (then world IS the
baseline). Until then it is the diff `features(LV) − features(world)`.

## Per-PR gates (every PR)

Relevant world/umbrella tests + `check_invariants` + `arch.scan` + `doc.scan` +
cap-elimination gates + **p13** + an agent-browser E2E for the surface. Run on an
**isolated `EZAGENT_HOME`** (not shared `~/.ezagent/default`).

## Open design questions (for Allen)

1. **gettext:** world currently has no i18n backend; LV owns `EzagentPluginLiveview.Gettext`
   (zh_CN translations). On retire, move the gettext backend into world or
   `ezagent_domain_ui`? (Recommend: `ezagent_domain_ui` so any plugin shares it.)
2. **Session detail route shape:** `/sessions/:id` (new) vs. in-place switch in
   `/sessions`. (Recommend `/sessions/:id` — deep-linkable, matches LV switch_session.)
3. **PR granularity / parallelism:** codex is on anon-user; I drive all 7 solo on
   `world`. OK, or split any PR to codex when it frees up?
