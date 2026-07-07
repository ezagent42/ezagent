# Hello member display names return

> **Task:** hello-session-member-display-names
> **Branch:** `codex/fix-hello-member-display-names`
> **PR:** https://github.com/ezagent42/ezagent/pull/1216
> **Dev:** Codex
> **returned_at:** 2026-07-07 16:02 +0800
> **deadline:** n/a
> **deadline_status:** out_of_scope

## What's done

- Fixed the session member panel so unprofiled UUID-backed agent members display their session `role_name` instead of the URI/id fallback.
- Preserved explicit entity profile display names: `role_name` is used only when the presenter result is the URI/path-segment fallback.
- Updated the chat composer `@` mention picker so the primary row label uses the same member display label, with the real `@token` kept as secondary text and insertion target.
- Added regression coverage for UUID agent member display and a structural UI guard for the mention picker label contract.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | Hello-template built-in agents should not show UUID/id as the visible name in the session member list. | met | `ConversationData.member_options/1` now falls back to `role_name` for unprofiled agent URI fallbacks; covered by `apps/ezagent_plugin_world/test/ezagent/world/conversation_invite_candidates_test.exs`. |
| 2 | The chat composer `@` member picker should also prioritize names instead of ids. | met | `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx` renders `memberLabel(member)` as the primary picker label and keeps `@{token}` secondary; guarded by `apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`. |
| 3 | Mention insertion must remain parser-safe. | met | Picker display changed only; `insertMention/1` still inserts `@${uriSegment(member.uri)}`. |
| 4 | PR branch is based on current `main` and locally green. | met | rebase-base SHA `dcabf617415f01aada70d23c6dcdb7c18ff6ce28`; code head SHA before this return-document commit `6873b8ec8a104f9bce11029e1307cbc947fe46f1`. |
| 5 | Machine gates are reported with concrete status. | met | Local `mix precommit` passed with WSL PATH exposing `/tmp/ezagent-pg-bin/{pg_dump,pg_restore}`. GitHub `gate (deterministic)` passed: https://github.com/ezagent42/ezagent/actions/runs/28852092920/job/85569672957. `gitleaks secret scan` passed: https://github.com/ezagent42/ezagent/actions/runs/28852092920/job/85569672867. `full-suite (self-hosted macOS)` was still pending at return time: https://github.com/ezagent42/ezagent/actions/runs/28852092920/job/85570061360. |

**Method friction:** The original symptom looked like a backend-only display-name bug, but the composer mention picker had an independent UI ordering problem: it displayed `@uriSegment` first even after the backend sent a better label. Future handoffs for display-name work should explicitly enumerate all surfaces that render the same entity identity: member panel, mention picker, routing selectors, message sender labels, and invite selectors.

## Verification

- `node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`
- `npm run build` in `apps/ezagent_plugin_world/assets`
- `mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_invite_candidates_test.exs`
- `env PATH=/tmp/ezagent-pg-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin mix precommit`

## Merge request

Please review and merge PR #1216 when the remaining self-hosted macOS full-suite check completes, assuming it stays green. The PR is draft-created and contains two code commits before this return document.
