# LV→world parity migration — Claude→codex handoff (2026-06-21)

**Handing the COMPLETE remaining plugin-world implementation back to codex**
(Allen directive, 2026-06-21). Claude landed PR-1..PR-3b; codex resumes at PR-4
and drives through PR-7 (LV retirement).

- **Branch:** `world` @ `09ad9732` (worktree `/Users/h2oslabs/Workspace/esr-ng/.worktrees/elim`, based on latest main).
- **Goal:** `ezagent_plugin_world` reproduces EVERY `ezagent_plugin_liveview`
  feature, then LV is deleted.
- **Authoritative refs (already on branch):**
  - `docs/superpowers/specs/2026-06-21-world-lv-parity-migration-spec.md` (8-PR plan + codex review revisions)
  - `docs/superpowers/specs/2026-06-21-world-lv-parity-INVENTORY.md` (LV feature inventory)
  - `apps/ezagent_plugin_world/test/ezagent/world/lv_parity_test.exs` (the ratchet gate)

## Completion gate (verification, superset of human review)

1. `lv_parity_test.exs` `@pending_migration == []` (all 59 features claimed).
2. `apps/ezagent_plugin_liveview` deleted; full umbrella
   `mix compile --warnings-as-errors --force` + `mix test` + boot all green.
3. router has no `EzagentPluginLiveview` scope.
4. agent-browser screenshots prove each surface works.

## DONE (Claude, PR-1..PR-3b) — ratchet 44 → 30

| PR | commit | what |
|----|--------|------|
| PR-1 | `3ac1bf43`/`7c1b58c9` | conversation core: message stream + composer (`:session :send`) + inbound PubSub bridge (`{:chat_message,uri,%Message{}}` → push_event) + `?session=` deep-link + load_older + mark_displayed |
| PR-2a | `8159ab37` | @mention: server-side `ConversationData.parse_mentions/2` + composer autocomplete |
| PR-3a | `66f37b0b` | members panel + **self-join on view** (`ConversationActions.self_join/2`) so persisted members surface on a cold session; + E2E seed recipe (`scripts/world_e2e_seed.exs`, `docs/guide/world-e2e-seed.md`) |
| PR-2b | `be53adb6`(backend)+`06a1d833`(client) | file upload via `:session :attach` dispatch chokepoint + signed anti-laundering grants + download links + composer paperclip/chips |
| PR-3b | `09ad9732` | session invite (members-panel Invite → modal → `:session :join` + demand-spawn) + **dispatch-router extraction** |

## Load-bearing architecture (FOLLOW THESE — they're why the gates stay green)

1. **All conversation `world:dispatch` actions route through ONE clause** in
   `world_live.ex` → `Ezagent.World.ConversationActions.handle_dispatch/3`. Add
   every new conversation action there (and to the `@conversation_actions`
   guard list in `world_live.ex`), NEVER as a new `world_live` handle_event
   clause. world_live is at 955 LOC; the arch gate `oversized_modules_gt_1000`
   (cap 3) fails the moment it crosses 1000.
2. **Module split:** pure read-path → `Ezagent.World.ConversationData` (no LV
   deps, no socket); socket actions/dispatch → `Ezagent.World.ConversationActions`
   (imports Phoenix.LiveView). Non-conversation surfaces have their own
   `*_data.ex` (workspace_plugin_data, identity_data, layout, etc).
3. **CapBAC (#154):** authorization is a cap check at the dispatch chokepoint.
   The controller/LiveView passes EMPTY ctx caps; the runtime derives authority
   from the caller's live slice (granted-via). NEVER enumerate caps caller-side
   (`Identity.list_caps_for` is a p13 violation — and a `lib/` COMMENT containing
   that literal string ALSO trips the p13 regex; reword). Same trap with
   `admin_uri()`. Use `Ezagent.Identity.admin?/1` if an admin shortcut is needed.
4. **New Session action** ⇒ (a) declare `action(:x, caps: [:x], ...)` +
   `handle_x/2` in `Ezagent.Behavior.Session`; (b) **hand-register** in
   `EzagentDomainInstanceMessage.Application.register_session_behaviors`
   (`CapabilityRegistry.register(Session, :x, SessionBehavior)` — it is a
   HARDCODED list, not auto-derived; miss it → `{:error,{:unknown_action,_}}`);
   (c) if members need it, add to the participation tier
   `Membership.@member_chat_actions`. The runtime checks the DISPATCHED action
   name against held-cap action — `caps:[:send]` is NOT an alias for another
   action.
5. **`@doc` must immediately precede `@spec`/`def`** — module attributes between
   them detach the doc and trip doc.scan. Find offenders:
   `mix run --no-start -e 'Mix.Tasks.Ezagent.Doc.Scan.offenders()[:defs] |> ...'`.

## Survivor APIs (re-derive against these, NOT LV)

`Ezagent.MessageStore.recent_in_session/2`+`older_than/3` ·
`Ezagent.EntityPresenter.display_many/1`+`display/1` ·
`Ezagent.Behavior.Session.session_events_topic/1` ·
`Ezagent.Session.ReadMarker.mark/4` · `Ezagent.Message.new/3` ·
`Ezagent.Kind.get_slice(uri, :session)` (members `%{uri=>%{online:bool}}`) ·
`Ezagent.Capability.matches?/2`+`workspace_of/1` ·
`Ezagent.Uploads.store_upload!/3`+`store!/3`+`DownloadToken.mint!/verify` ·
`Ezagent.Behavior.Session.Membership.{provision_join_authority,mount_participation_caps}/2` ·
`Ezagent.SpawnRegistry.spawn/1` (demand-spawn a cold member before `:join`) ·
`Ezagent.Workspace.create_session/3`+`remove_member/3`.

## REMAINING WORK (ratchet 30 → 0)

### PR-4 (largest) — session ops
LV refs in `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex`:
- `create_session` (admin_live:425, → `Ezagent.Workspace.create_session/3`) —
  add a "New session" affordance to `SessionsTable.tsx`; new dispatch action
  through `handle_dispatch`. NOTE: `create_session` spawns the cc-orchestrator
  (heavy; in tests it can time out on the claude trust-dialog but the session
  IS persisted — assert on the persisted session, not the orchestrator).
- `restart_orchestrator` (admin_live) — dispatch lifecycle.terminate on the
  session's orchestrator agent.
- `switch_view` / `switch_to_pty_for_agent` — switch the conversation ↔ a
  member-agent's PTY terminal (world already has a `pty_terminal` component +
  `PtyTerminal.tsx`; wire the view switch).
- `routing_rule_add_session` / `routing_rule_toggle` — per-session routing rules
  (`Behavior.Routing` auto-derives on the Session Kind; `mix ezagent session
  add_rule` is the CLI parity). World already has a workspace routing surface to
  mirror.
- `toggle_debug_panel` / `toggle_expand` — likely client-only UI toggles (like
  open/close_invite_modal); verify they aren't tied to a server action.

### PR-5 — auto-derive detail + credential cascade
`set_default_source`, `save_smtp`, `send_test_email`, `update_test_recipient`
(admin settings/SMTP), `edit_display_name`/`save_display_name`/
`cancel_edit_display_name` (entity display-name inline edit),
`bind`/`unbind` (feishu channel bindings — `ExternalMirror`/binding surface).

### PR-6 — command palette + workspace remove
`cmdk_open`/`cmdk_close`/`cmdk_query`/`cmdk_select` (the ⌘K palette — client
state + a select→navigate dispatch), `remove_member` (WORKSPACE member removal,
`Ezagent.Workspace.remove_member/3`, on the world workspace surface — NOT the
session panel; world's `workspace_plugin_data` already exposes `members`).

### Inbound `handle_info` realtime (spread across PR-4..6)
`notification`, `read_marker_updated`, `cc_event`, `cc_connected`,
`cc_disconnected`, `slice_changed`, `audit_event`, `authz_event`. LV subscribes
in `admin_live.ex:~102-115`. World pattern: `WorldLive` subscribes to the topic,
`handle_info(...)` → `push_event` to the React island (mirror the PR-1
`{:chat_message,...}` bridge + PR-3a `members:update`).

### PR-7 — cutover + delete LV (the completion gate)
Cleanup sites: root `mix.exs` `:permanent`, `ezagent_web` dep on LV,
`app.css` `@source`, gettext → `ezagent_domain_ui`, `arch.scan.ex` LV paths,
`lv_cli_parity_test` / `workspace_lv_cli_parity_test`, router scope, then delete
`apps/ezagent_plugin_liveview`. Then full umbrella green.

## Per-PR loop (proven this session — DO EVERY STEP)

1. Implement; route new conversation actions via `handle_dispatch` (not world_live).
2. Tests. **DB-touching tests** (anything resolving display names via Repo, e.g.
   `build_message`/`message_row`) go in `apps/ezagent_web/test/.../world_conversation_test.exs`
   (a sandbox-backed `ConnCase`), NOT in the `async: true` plugin test
   (`conversation_data_test.exs`) — else `DBConnection.OwnershipError` under the
   combined `mix test`. Pure tests (`parse_mentions`) stay in the plugin test.
   Genesis `session://system/default/main` is the only always-live session;
   `:join`/`:send`/`:attach` do NOT create sessions, so tests target `main`
   (don't kill it — it's supervisor-managed) or create via
   `Workspace.create_session/3`.
3. Shrink `lv_parity_test.exs` `@pending_migration` + lower `@pending_baseline`.
4. Gates: `mix ezagent.arch.scan` · `mix ezagent.doc.scan` ·
   `mix test apps/ezagent_core/test/invariants/` (incl p13
   `cap_check_only_at_chokepoint_test`) · world + web suites.
5. `cd apps/ezagent_plugin_world/assets && pnpm run build` (vite; prod bundle to
   `ezagent_web/priv/static/assets/world/` which is GITIGNORED — commit only
   `assets/src/**`).
6. agent-browser E2E on the ISOLATED home (`EZAGENT_HOME=/tmp/ezagent_pr1_e2e`,
   never `~/.ezagent/default`). Recipe: `docs/guide/world-e2e-seed.md`. Start:
   `lsof -ti :4020|xargs kill -9; lsof -ti :5175|xargs kill -9` then
   `PORT=4020 PHX_HOST=0.0.0.0 WORLD_VITE_PORT=5175 EZAGENT_HOME=/tmp/ezagent_pr1_e2e mix phx.server`.
   agent-browser launch arg `--host-resolver-rules=MAP world.ezagent.chat 127.0.0.1`,
   nav `http://world.ezagent.chat:4020`. Login: fill the **2 VISIBLE** inputs
   (`entity_uri`,`secret`) — the first `<input>` is the hidden `_csrf_token`;
   use the FULL URI `entity://system/user/admin` + password `worlddev` (seeded).
   Kill phx by `lsof -ti :4020|xargs kill -9` (NOT `pkill -f PORT=4020` — env
   vars aren't in argv).
7. Commit + push `world`; Feishu screenshot to Allen
   (`oc_d9b47511b085e9d5b66c4595b3ef9bb9`).

## codex-specific notes
- codex-rescue runs in an isolated MIX_HOME without deps → **static analysis
  only, no mix/elixir/test commands** (they fail). For implementation codex
  needs the real worktree + deps.
- Full state + every gotcha is in memory `project_world_review_role_swap`
  (Claude's memory; mirrored here). Lessons: `feedback_replacement_task_gate_is_parity_audit`,
  `feedback_completion_requires_invariant_test`.
