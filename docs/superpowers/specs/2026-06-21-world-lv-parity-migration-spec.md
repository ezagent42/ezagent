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

- LiveView (`WorldLive`) = SSR/comms shell: auth (`:require_entity`), routing,
  the `WorldRenderer` phx-hook, `Invocation.dispatch/1` for every mutation
  (**outbound**), AND — critically — the **inbound realtime bridge** (below).
- React/shadcn owns all rendering; calls the **same domain dispatch actions** LV
  calls (chat.send, session.join, member invite, etc.). Business logic stays in
  the domain plugins (im/session/socialware/pty) — untouched.
- `ezagent_domain_ui` (shared atom layer) is consumed by both and **survives**.

### Inbound realtime bridge (codex C1 — the highest-risk piece)

`AdminLive` is NOT just outbound dispatch. In `mount` it subscribes to many
PubSub topics — per-session chat, presence, notifications, slice-change, CC
events, bridge connect/disconnect, audit — and `handle_info` mutates visible
state (`admin_live.ex:101-118, 202-290`). It also uses **Phoenix LiveView
uploads** (`live_file_input` + `consume_uploaded_entries/3`;
`admin_live.ex:155-159`, `session_editor.ex:521-552`, `compose.ex:68-74`).

Because `WorldLive` is itself a LiveView, the bridge is: WorldLive subscribes to
the SAME topics server-side and `push_event`s incremental updates to the React
island (new message, member join/left, presence, notification flash). Uploads
stay on the LiveView side (`live_file_input` rendered by the SSR shell + a hook),
OR move to an explicitly cap-authorized HTTP upload endpoint — **decide in PR-2**.
Parity tests MUST cover INBOUND events (a PubSub `{:chat_message,...}` reaches
the React island), not only outbound dispatch.

## Parity map (LV surface → world status)

✅ = present & real in world · 🟥 = MISSING (this migration)

| LV surface | world status |
|---|---|
| Identities: users/agents list, caps, api-keys, extensions, new, detail | ✅ |
| PTY terminal (pty_input/resize) | ✅ |
| Workspaces list + detail | ✅ |
| Plugins: feishu bindings | ✅ |
| Plugins: auto-derive **list** | ✅ |
| Plugins: auto-derive **DETAIL** (embeds credential cascade: `set_default_source`/`revoke_credential_grant`) | 🟥 (codex H3 — world auto-detail only dumps JSON; cascade controls missing) |
| Profile | ✅ |
| Admin: dashboard, observability, registry, snapshots, templates, caps, authz-audit, settings, routing | ✅ (real data) |
| Admin: external-mirror (`refresh`/`add_binding`/`unbind`/`toggle_expand`) | ⚠️ route exists — VERIFY events wired (codex H1) |
| **Session conversation page** (`AdminLive`) | 🟥 — world `/sessions` is only a list table |
| credential_cascade_ui (#17) | 🟥 (part of auto-derive detail, above) |
| command_palette (cmdk: `cmdk_open/close/query/select`) | 🟥 (primitive exists, not wired) |

> **codex H1:** this map is a starting point, NOT authoritative. PR-0 extracts
> the FULL inventory (routes + LiveViews + LiveComponents + every `handle_event`
> + `handle_info` + `phx-*` bindings + uploads + PubSub subs + registered session
> views) — that inventory is the real completion criterion (the lesson from
> `feedback_replacement_task_gate_is_parity_audit`).

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

- **PR-0 — Inventory + parity gate (do FIRST):** extract the FULL LV surface
  inventory (codex H1/M1): every router route, LiveView, LiveComponent,
  `handle_event`, `handle_info`, HEEx `phx-*` binding, upload declaration, PubSub
  subscription, and registered `ezagent_domain_ui` session view. Commit it as a
  data file + a **parity test** that fails when world lacks any inventory entry.
  This inventory — not the hand map above — is the completion criterion. Gate:
  the parity test runs (RED is expected until PR-7; it tracks the diff).
- **PR-1 — Session conversation core:** React `Conversation` component + message
  stream + composer (send via `:session :send` dispatch, `compose.ex:99-108`) +
  switch_session + the **inbound bridge** (WorldLive subscribes per-session chat
  topic → `push_event` new messages, mirroring `admin_live.ex` stream_insert).
  **Route (codex H2): KEEP the existing `?session=<encoded>` deep-link contract**
  (`admin_live.ex:164-178`; command palette emits `/sessions?session=`), NOT a
  new `/sessions/:id` — selection is a query param on `/sessions`. Gate:
  agent-browser send-a-message E2E **+ inbound test** (a PubSub chat message
  reaches the island).
- **PR-2 — Mentions + file upload:** inline `@mention` autocomplete (member
  options) + file upload/cancel in composer. Gate: E2E @mention + attach.
- **PR-3 — Members + invite:** members panel (list + presence) + invite modal
  (`invite_member`). Gate: E2E invite a member.
- **PR-4 — Session lifecycle:** create_session form + restart_orchestrator +
  per-session routing rules (add/toggle) + view-switch (chat ↔ PTY). Gate: E2E
  create session + restart.
- **PR-5 — Auto-derive DETAIL + credential cascade (codex H3):** credential
  cascade is EMBEDDED in LV's `auto_derive_live` detail (`set_default_source`,
  `revoke_credential_grant`; `auto_derive_live.ex:27-40,283-386`). Build world's
  auto-derive detail (not JSON dump) with the cascade panel + those dispatches.
- **PR-6 — command_palette wiring:** wire the existing primitive to
  `CommandSource`/command routes (`cmdk_open/close/query/select`); preserve the
  `/sessions?session=` emit (codex H2). Also verify external-mirror events
  (`refresh`/`add_binding`/`unbind`/`toggle_expand`) are wired in world (codex H1).
- **PR-7 — Cutover + retire LV (codex C2 — enumerate ALL cleanup sites):**
  1. router: remove the `EzagentPluginLiveview` scope (`router.ex:150`) + fix
     `live_auth.ex:21`; world host owns all routes.
  2. root `mix.exs` startup: remove `ezagent_plugin_liveview: :permanent`.
  3. `ezagent_web/mix.exs`: drop the `{:ezagent_plugin_liveview,...}` dep.
  4. `ezagent_web/assets/css/app.css:8-12`: remove the `@source` scan of the LV dir.
  5. gettext: move backend/catalog to `ezagent_domain_ui` (recommended) + update
     `gettext_test.exs:39-43` + locale propagation in `live_auth.ex:75-79`.
  6. core gates with literal LV paths: `ezagent.arch.scan.ex:24-27`,
     `ezagent.check_invariants.ex:262-264`.
  7. LV-specific invariant tests: `workspace_lv_cli_parity_test.exs`,
     `lv_cli_parity_test.exs` — retire or retarget at world.
  8. delete `apps/ezagent_plugin_liveview`.
  Gate: full umbrella **boot + compile + test** green with the LV app deleted;
  the PR-0 parity gate now GREEN.

## Parity gate (the completion test) — built in PR-0

A new arch/invariant test enumerates LV's user-facing surfaces and asserts world
covers each — fails when world lacks a feature LV has. The gate that would have
caught the original gap. Extractor scope (codex M1 — NOT just routes+events):
router routes · LiveViews · **LiveComponents** (`phx-target={@myself}` events are
invisible to parent inventory, e.g. command palette `command_palette_component.ex`)
· every `handle_event` (incl. dynamically-guarded clauses delegated to helpers,
e.g. routing rules `admin_live.ex:642`) · **`handle_info`** · HEEx `phx-*`
bindings · **upload declarations** · **PubSub subscriptions** · registered
`ezagent_domain_ui` session views (`session_view.ex:10-15,51-86`). Diff
`features(LV) − features(world)`; trivial once LV is deleted at PR-7.

## Per-PR gates (every PR)

Relevant world/umbrella tests + `check_invariants` + `arch.scan` + `doc.scan` +
cap-elimination gates + **p13** + an agent-browser E2E for the surface. Run on an
**isolated `EZAGENT_HOME`** (not shared `~/.ezagent/default`).

## Decisions (small Qs — decided per Allen "大的open question再问我")

1. **gettext:** move backend/catalog to `ezagent_domain_ui` (shared by any
   plugin) at PR-7; update `gettext_test` + `live_auth` locale propagation.
2. **Session route:** KEEP existing `/sessions?session=<encoded>` (codex H2 — it's
   the live deep-link contract the command palette emits); NOT `/sessions/:id`.
3. **Parallelism:** Claude drives all 8 PRs solo (codex on anon-user); revisit if
   codex frees.

## codex adversarial review — incorporated

Run 2026-06-21. All findings folded in: C1 (inbound realtime bridge + uploads
→ Architecture section + PR-1/PR-2), C2 (PR-7 full cleanup enumeration), H1
(PR-0 full inventory replaces hand map), H2 (keep `?session=`), H3 (cascade ∈
auto-derive detail = PR-5), M1 (parity-gate extractor scope), M2 (gettext breadth
→ PR-7), M3 (dead `unbind_feishu_chat` button — clean up in PR-6).
