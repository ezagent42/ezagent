# Return: Agent Console CRUD (world)

> **Task:** #84 (re-scope) — Agent-contract CRUD slice in `world` (handoff `docs/together/2026-06-24/handoffs/agent-console-crud-handoff.draft.md`)
> **Branch:** `feat/agent-console-crud`
> **PR:** https://github.com/ezagent42/ezagent/pull/958
> **Dev:** Claude (via @戴明)
> **returned_at:** 2026-06-24 +0800
> **deadline:** — (no hard deadline in the handoff)
> **deadline_status:** on_time

## What's done
Full agent-contract CRUD from the `world` UI, on the #905 base, over #938's `Ezagent.AgentConfig` facade (+ #943 cap-gated reads):
- **Create:** anti-stub regression (created agent appears in `list_entities`) + cwd-required failure path.
- **Read:** detail/list; **fixed** a live-status bug (detail Phase "unknown" for live agents — `jsonable/1` ran `Map.from_struct/1` on a plain map → rescued → stringified).
- **Update:** new `/identities/agents/:uri/config` sub-route (slot-registered + Phoenix route); `read_cascade/4` cap-gated read; key/value editor (user-layer editable, workspace/session read-only); `agents.config.update`/`delete_path`/`repoint` dispatch → facade; re-read after mutation (no in-form echo).
- **Delete:** `agents.delete` → `Manage.:delete` + manage-cap + bound-session block via `agent_live_sessions/1` (lists blocking sessions) + two-click confirm.
- **Structure:** agent dispatch extracted to `Ezagent.World.AgentActions` (world_live 1087→784, under the 1000-LOC arch cap).

Every read+mutation routes through the cap-gated facade/dispatch — world never touches `ConfigStore`, never synthesizes a cap, no silent drops.

## DoD artifact
- **Live E2E (full CRUD, pinned to backend state):** `docs/superpowers/notes/2026-06-24-agent-console-crud-e2e-evidence.md` + screenshots committed under `docs/together/2026-06-24/evidence/agent-console-crud/` (config editor showing a durable `tone=decisive`; agents list).
  - create→manage-cap minted (audit `cap_granted`); config editor renders via `read_cascade`; `tone=decisive` persists across a fresh reload (durable read-back); `delete_path` removes the field durably; delete → `manage.delete` granted → `kind_snapshots` DELETE.
- Cap-denial + bound-session block covered by unit tests (`agent_delete_dispatch_test.exs`, `agent_config_dispatch_test.exs`).

## Branch + gate status
- 22 task commits + the merge — **every commit passed the full `mix test` gate**; `arch.scan`/`uri_query.scan`/`OversizedModulesTest`/`format` green; TSX build clean (0 new TS errors).
- Per-task implementer+reviewer; **opus whole-branch review: READY TO MERGE** (no Critical/Important).
- Rebased/merged onto latest `origin/main` (resolved #950 agent API-key UI + #949 logout vs our CRUD — kept both); PR `MERGEABLE`.

## Deferred / follow-ups (cleanly scoped, not blocking)
- **echo config editing → depends on #918** (open): `read_cascade` needs `ConfigEvolve` (only `Entity.Agent` riders: curl/cc-headless). On main, echo's config page graceful-errors until #918 lands.
- **Backend (→ @黄佳佳, already messaged):** `AgentConfig.delete_path/4` reads the body before the auth gate → no-cap caller on a *nonexistent* path gets `:path_not_found` before `:unauthorized` (existence info-leak; existing fields auth-gate correctly).
- **Minor (separate tasks):** config editor replaces the view with the error banner on a *mutation* failure (should render above the editor); friendlier message for `{:unknown_action,:read_cascade}`; **world `LiveViewTest` harness** (the missing config Phoenix route that 404'd in E2E would've been caught by one — dispatch tests currently run at the `Invocation` seam).
- **repoint:** backend dispatch wired; frontend UI deferred (not faked).

## Merge request
Merge **`feat/agent-console-crud` → `main`** via lead-close (not self-merged). Already on latest main, no conflicts. No ordering dependency to merge this PR; echo *config editing* only becomes usable once #918 also lands (independent merge).
