# Return — hello: AI-generated @json-render UI pages plugin (hello)

| Field | Value |
|---|---|
| Task | hello: AI-generated @json-render UI pages plugin |
| Branch | `hello` |
| PR | #891 |
| Dev / PR author | `zhaomaota97` |
| returned_at | 2026-06-22 20:32:25 +08:00 (backfilled from PR `updatedAt`; first return-ledger file commit was `3768b8e3` at 23:17) |
| deadline | 2026-06-22 20:00 +08:00 |
| deadline_status | `late` |
| close_status | Landed via lead squash/subsumed commit `d8c4a7f9`; PR #891 comment+closed on 2026-06-23 |

- **Branch:** `hello` (HEAD `808553f3`), **PR #891**
- **Base:** `world-beautify` (PR base = `world-beautify`; `world-beautify` IS an ancestor of `hello`). hello = world-beautify + ~47 files. → **must merge AFTER world-beautify**; inherits wb's rebase.
- **Author/dev:** zhaomaota97

## Scope
New plugin `ezagent_plugin_hello` — re-implements loom's core idea ("AI generates a UI page; anonymous visitor views it") on the proper ezagent substrate:
- AI builder agent generates a page: LLM emits a `@json-render` spec constrained by a Zod component catalog.
- Multi-agent fan-out (planner → workers → compose), Phase 1.
- Pages are born only via `Behavior.Surface.put_version` (driven by `Behavior.Turn`) → dispatch + CapBAC.
- Anonymous visitor views via socialware `public_view` → `CustomerFeed` → `/socialware/customer`.
- `session.hello` Template Class — creatable from the world console like a normal session (Phase 2).
- operator `@json-render` island (React 19) so the operator console renders real pages.

## DoD artifact (dev-reported)
- PR #891 open, rebased onto `world-beautify`. (Detailed gate evidence to be confirmed from the PR/branch during close.)

## Conflict / dependency notes (lead analysis)
- **Hard order:** world-beautify → hello (hello contains wb).
- Adds a new OTP app `ezagent_plugin_hello` → must be wired into `apps/ezagent_web/mix.exs` deps + root release apps list (`all_plugin_apps_wired_to_web_test`), and pass `:ezagent_plugin_check`.
- After pg lands, hello's new plugin + socialware/surface code must be **PG-compatible** (pg's `database_agnostic_guard_test` will scan it) and gates re-run **under PG**.

## Merge request
After world-beautify is merged (on post-pg main), rebase hello onto the new main, re-run gates under PG, confirm plugin wiring, then merge.
