# anon-user epic — codex self-drive handoff

Resolve ALL anon-user problems (closes #68), codex self-driven on the **`anon-user` branch**,
PR-per-step, all merged to `anon-user`. Claude reviews each PR into a standing review-log issue;
codex addresses findings per PR (same loop as `world`/#867).

## Inputs (read + critique before coding)
1. `docs/superpowers/specs/2026-06-21-message-session-scoping-design.md` (PR-1).
2. `docs/superpowers/specs/2026-06-21-anon-login-merge-FINAL-design.md` (PR-2+, decisions + B1/B2/H4/H5/H6 resolutions).
3. Load `Skill: esr-developer` + `Skill: elixir-phoenix-helper`. Reuse, don't reinvent: `ReadMarker.repoint/3`, `mount_participation_caps/2`, `provision_join_authority`, `MessageStore.mark_visibility/2` (mutation precedent), `AnonUser.GC` reap primitives, `AnonCookie`. Reference the jia5 mechanism: `git show feat/jia5-anon-takeover:apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex`.

## Working agreement (same as world)
- Fully self-driven, PR-per-step, all merged to `anon-user`. No waiting for confirmation.
- Each PR gate: relevant umbrella tests + `check_invariants` + `arch.scan` + `doc.scan` + the cap-elimination gates + **p13** (no `== admin_uri()`) + an agent-browser E2E where applicable.
- **#154 hard rule**: no `system://` principal; authz at the dispatch chokepoint via caps; never hardcode `caller == principal`.
- At each PR end, read the review-log issue #872 and address open findings.

## PR sequence

### PR-1 — message session-scoping (prerequisite; dissolves anon B3)
Per the message-session-scoping design: stop writing/reading `message_routings`; session-scope via `messages.session_uri`; rewrite the read queries (`recent_in_session`/`in_session_since`/`chat_visible_recent`/`committed_customer_visible*`) to `WHERE session_uri == ?` (no join); `sessions_for_message/1` → `[session_uri]` (+ fix `uploads_controller.ex:152`); data migration that **asserts 0 cross-session-divergent routings before dropping** (fail-loud if the vestigial assumption is wrong). Forwarding stays copy+`ref_id` (unchanged). **Gate:** all message/chat tests green with identical results; reads faster; gate suite green.

### PR-2 — `Session.merge_member/2` + atomicity scaffold (B1/B2)
Add `Behavior.Session` `merge_member(from, to)` (atomic slice: dedup membership + remove anon + rewrite `:last_message` + `member_joined`/`member_left`), socialware-symbol-free, via a direct `do_join`-composition helper (NOT dispatching `handle_join`). Add the durable merge-claim (`AnonBinding.merging_to`/`merge_state`) + idempotent steps + verify-before-delete (B2). **Gate:** unit tests for fresh + already-member dedup + idempotent re-run + crash-mid-merge repair.

### PR-3 — `MessageStore.relabel_identity/3` + `AnonCookie.verify_any/1` (H5)
`relabel_identity(session, from, to)` (sibling of `mark_visibility/2`; rewrites `sender`+`mentions`; safe post-PR-1). `AnonCookie.verify_any/1` (signature → `{anon_uri, session_uri}` → `AnonBinding` confirm). **Gate:** message-relabel tests; cookie verify tests incl. forgery/non-possessor rejection.

### PR-4 — orchestrator + single post-auth hook (H4/H6) — closes #68
The socialware `AnonTakeover` orchestrator (§7 of the FINAL design): hook on `SessionPrincipal.put/3` shared by all 3 login paths (credentials/magic-link/registration); verify_any → claim → provision join authority + dispatch `merge_member` → `relabel_identity` → mount confirmed caps (caller-side) → verify convergence → retire anon. Authority = signed-cookie possession + binding confirm (H6), no `:takeover` cap (LOW-8), no `system://`. **Gate:** agent-browser E2E (anon browses public session → logs in via each path → footprint claimed, anon gone, no dangling ref); non-possessor cannot trigger; full gate suite + p13 green.

## The prompt to give codex (paste)
```
You are resolving the ezagent anon-user epic (closes #68), fully self-driven on the `anon-user`
branch: PR per step, each gate-green with an agent-browser E2E where applicable, all merged to
`anon-user`, no waiting.

FIRST read + critique (flag anything wrong before coding):
  docs/superpowers/specs/2026-06-21-message-session-scoping-design.md
  docs/superpowers/specs/2026-06-21-anon-login-merge-FINAL-design.md
  docs/superpowers/plans/2026-06-21-anon-user-epic-codex-handoff.md
Load the ezagent-developer skill. Reuse (don't reinvent): ReadMarker.repoint/3,
mount_participation_caps/2, provision_join_authority, MessageStore.mark_visibility/2,
AnonUser.GC, AnonCookie. Reference jia5's membership.ex for the existing mechanism.

Honor #154 (no system:// principal; authz via caps at the dispatch chokepoint; never hardcode
caller == admin_uri() — probe p13 will fail it). Keep merge_member socialware-symbol-free;
mount caps OUTSIDE the Session Kind (caller-side, avoids self-deadlock). Messages become
session-scoped in PR-1 (cross-session = copy+ref, never shared-id routing).

Execute PR-1 (message session-scoping) → PR-2 (merge_member + atomicity claim/repair) →
PR-3 (MessageStore.relabel_identity + AnonCookie.verify_any) → PR-4 (AnonTakeover orchestrator
+ single post-auth hook across all 3 login paths). Each PR: implement → tests + check_invariants
+ arch.scan + doc.scan + cap-elimination gates + p13 green → agent-browser E2E → commit → merge
to `anon-user`. At each PR end, read GitHub issue #872 and address open
findings. Done = an anon views a public session, logs in via any path, their footprint is under
the login entity, the anon user+binding are gone, no dangling anon_uri, non-possessor cannot
trigger, all gates green.
```

## After codex finishes
Claude checks out `anon-user`, runs the full gate suite + the agent-browser E2E, reviews against the
acceptance (§9 of the FINAL design), and confirms #68 closed.
