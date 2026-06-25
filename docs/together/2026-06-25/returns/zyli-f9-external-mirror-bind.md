> **Task:** F9 — operator UI to bind Feishu chat→session (external mirror)
> **Branch:** `feat/product-gaps-f9-f12`
> **PR:** #975 (https://github.com/ezagent42/ezagent/pull/975)
> **Dev:** zyli (agent: Claude Opus 4.8)
> **returned_at:** 2026-06-25 11:37 +0800
> **deadline:** 2026-06-25 23:59 +0800
> **deadline_status:** on_time

## What's done

Closes the **F9** gap from the 2026-06-24 full-flow validation: the world **External Mirror** surface was read-only — binding a Feishu chat to a session only had the `mix ezagent.external_mirror.bind` CLI + the `Ezagent.ExternalMirror.bind/5` facade, with **no operator UI**. This PR wires the existing facade to the world UI (`lv_cli_parity`), and adds the missing navigation entry (Sessions row → External mirror).

## DoD reconciliation
| # | DoD line | status | proof |
|---|----------|--------|-------|
| 1 | Operator UI exposes a bind form for external mirror (Feishu chat→session) | met | `Admin.tsx` ExternalMirror surface — Adapter/Target form; screenshot `docs/together/2026-06-25/evidence/f9-external-mirror-bind-form.png` |
| 2 | Per-binding unbind from the UI | met | `Admin.tsx` per-row unbind button → `external_mirror.unbind` |
| 3 | Operator can NAVIGATE to the bind surface (no URL-typing) | met | `SessionsTable.tsx` row link → `/admin/sessions/:id/external_mirror`; screenshot `f9-sessions-external-mirror-entry.png` |
| 4 | Backend wired through the facade (CapBAC + target_ownership_check honored, no bypass) | met | `admin_actions.ex` calls `Ezagent.ExternalMirror.bind/5`/`unbind/4` with caller ctx off the socket (P14) |
| 5 | Tests | met | `admin_actions_external_mirror_test.exs` 9/9; world suite 23/23 (lv_parity/slot/routes/mount gates); tsc + vite build + check:mounts OK |
| 6 | Live demonstrable end-to-end | met | agent-browser: Sessions → External mirror → Bind reaches the **real Feishu Lark API** (`target_ownership_check`); `data-last-dispatch = error:{:target_ownership_denied, {:lark_check_failed, {:http_status, 400, …}}}` proves full UI→facade wiring. Evidence: `docs/together/2026-06-25/evidence/f9-live-verification.md` |

**Method friction:** the handoff was informal (no formal handoff file for these validation-derived gaps), and the DoD as written ("no UI to bind") under-specified that the bind *page itself had no nav entry* — discovered only in self-test. A demonstrable-DoD handoff would have caught the discoverability half up front. F12's scope also turned out to collide with a documented Allen decision (see deferred).

## Branch + gate status
- **CI run:** https://github.com/ezagent42/ezagent/actions/runs/28144971062 — PASS (commit 036380b3; `precommit + check_invariants` green, 4m26s; two advisory checks green). Note: an earlier run on the prior commit was RED on `Ezagent.Architecture.UndeclaredUmbrellaDepTest` (#57) — `ezagent_plugin_world` lib hard-referenced `Ezagent.ExternalMirror` without a declared `in_umbrella` prod dep; fixed in 036380b3 by declaring `{:ezagent_domain_external_mirror, in_umbrella: true}` in `apps/ezagent_plugin_world/mix.exs`.
- **Rebase base:** branch cut from `origin/main` @ `c809d3b3`. **main has since advanced to `ae6420fc`** — a **rebase is owed before merge**.

## Deferred follow-up (open decision for the lead)
- **F12 (Feishu @ → agent mention)** — **split out of this PR**, intentionally NOT included. It collides with Allen's 2026-05-17 decision (text-grep `@<agent-name>`, deliberately NOT reading the Feishu payload `mentioned_users`). Chosen direction **C** (placeholder→text bridge) **needs Allen sign-off before merge**. Full code-surface map + owner split (林懿伦 routing / 张宁 session-rule UI) in `docs/together/2026-06-25/notes/f12-feishu-mention-coordination.md`. **Status update (2026-06-25 PM): direction C is now implemented + pushed** on `feat/f12-feishu-mention-bridge` (EventDecoder placeholder→`@<name>` rewrite; 7 unit + 2 e2e tests; full feishu suite 188/0) — **unmerged, PR pending Allen sign-off**.

## Merge request
- Merge **PR #975** (`feat/product-gaps-f9-f12` → `main`) after CI green. Self-contained F9; no cross-PR ordering dependency. **Rebase onto current main (`ae6420fc`) first.** F12 is a separate future PR gated on Allen sign-off.
