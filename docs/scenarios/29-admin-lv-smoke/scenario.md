# Scenario 29: Admin LV smoke — registry / snapshots / templates / routing / cmdK

**Category**: 17 — Admin LV pages
**Status**: ⚠️ implemented-with-gaps
**Last verified**: 2026-05-26 (per-LV manual smokes; `/admin/agents` 404 still open)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Admin logged in
- A populated workspace (scenarios 09, 14, 22 all ran)

## Actors

- **Caller**: admin
- **Targets**: every `/admin/*` LV page

## Steps

### Per-LV walkthrough

1. `/admin` — root: workspace dropdown, chat, dispatch input. ✅
2. `/admin/users` — list, mint token, set password. ✅ (LV bypass gap exists per todo HIGH-4)
3. `/admin/users/<u>/caps` — list, grant, revoke (action-selector dropdown gap exists per todo). ✅
4. `/admin/workspaces` — list. Click into one. ✅
5. `/admin/workspaces/<ws>` — detail: members, sessions, templates, routing. ✅
6. `/admin/workspaces/<ws>/routing` — per-WS routing rules CRUD. ✅
7. `/admin/sessions/<s>` — chat + roster + dispatch. ✅
8. `/admin/sessions/<s>/routing` — per-session routing rules (PR #418 fix). ✅
9. `/admin/sessions/<s>/external-mirror` — bindings (scenario 12). ✅
10. `/admin/agents/<a>/terminal` — live PTY mirror. ✅
11. `/admin/agents/<a>/api-keys` — per-agent api-keys (PR #389). ✅
12. `/admin/templates` — list + create. ✅
13. `/admin/routing` — global rules (PR #120 system default visible + admin-disable-only). ✅
14. `/admin/registry` — live KindRegistry snapshot. ✅
15. `/admin/snapshots` — kind_snapshots browse + dump + clear. ✅
16. `/admin/events` — ❌ does not exist (scenario 28).
17. `/admin/agents` (top-level agent list) — ❌ returns 404 today (gap).

### cmdK search

18. Press `Cmd+K` (or `Ctrl+K`); cmdK palette opens.
19. Type a partial URI: `echo_1`. Verify it resolves agents matching.
20. Type an action verb: `chat send`. Verify it suggests `chat.send` against contextual targets.
21. Per SPEC `2026-05-22-v1-uri-pickers-and-cmdk.md`, the palette should cover sessions, entities, actions, and routes.

### Per-Kind admin auto-derivation

22. From `/admin/registry`, click into a Kind row.
23. Verify the auto-derived admin form (compile-time generated from `@interface`) renders + dispatches correctly.

## Expected outcomes

- ALL LV pages mount within 1s for a reasonable-sized DB (<10k rows per table).
- cmdK is keyboard-driven + responsive (no full-page re-render).
- Workspace dropdown filters all per-WS pages consistently.
- `/admin/agents` 404 is an honest gap (no broken-not-404 mystery).

## Failure modes to test

- Stale LV socket after deploy: forced reconnect; assigns re-mounted.
- Concurrent admin sessions: optimistic concurrency on writes; PR #422 broke + fixed.
- Workspace switch mid-LV-action: assigns invalidated; LV may flash redirect.

## Cross-references

- Related PRs:
  - PR #401 — fix(ui): icon SVG path-join bug
  - PR #418 — session routing nav
  - PR #422 — chore(test): repair umbrella-wide baseline (includes UI fixes)
  - PR #434 — cap-based workspace visibility (dropdown change)
  - PR #455+ — pending: `/admin/events` LV
- Related SPECs:
  - `docs/superpowers/specs/2026-05-22-v1-uri-pickers-and-cmdk.md`
  - `docs/superpowers/specs/2026-05-20-phase-8b-session-lv-redesign.zh_cn.md`
- Tests:
  - `apps/ezagent_plugin_liveview/test/integration/plugin_contract_test.exs`
- Evidence:
  - `docs/notes/phase-9-demo-2026-05-21.md` — LV screenshots
- Open bugs / gaps:
  - `/admin/agents` 404 — top-level agent list never shipped; admin uses cmdK or per-session roster instead.
  - `/admin/events` not shipped; scenario 28 tracks the audit-LV gap.

## Notes

- Per `feedback_open_terminal_first_when_debugging`, `/admin/agents/<a>/terminal` is the canonical first debug stop.
- The auto-derived admin forms (`form_fields/0`) are the test of plugin-isolation: a plugin author should not write any LV code to get a usable admin UI.
- cmdK + URI picker (SPEC `v1-uri-pickers-and-cmdk`) is the user-facing manifestation of `feedback_converge_to_uri_list` — every input surface eventually feeds the same `[URI.t()]` shape.
