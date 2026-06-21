# Claude Handoff — anon-user acceptance and merge

Claude is taking over after Codex completed the anon-user epic implementation on the local
`anon-user` branch. This handoff is for independent verification, issue-log closure, and final
publication/merge of the branch.

## 0. Current branch state

Worktree used by Codex:

```bash
cd /Users/h2oslabs/Workspace/esr-ng/.worktrees/alias
git status --short --branch
```

Expected implementation state before this handoff doc is committed:

```text
## anon-user...origin/anon-user [ahead 6]
```

After this handoff doc is committed, `anon-user` may be ahead by 7 and `HEAD` may be the
docs-only handoff commit. The implementation merge commit must still be reachable:

```text
561fe0a1 (HEAD -> anon-user) Merge PR-4 anon takeover hook
3eb6d3ea (codex/anon-user-pr4-takeover-hook) feat(anon-user): add post-auth anon takeover
c8a18fde Merge PR-3 anon relabel identity
2fab9302 (codex/anon-user-pr3-relabel-identity) Implement anon identity relabel primitives
b8860f0a merge PR-2 anon merge member claim repair
048c82c3 (codex/anon-user-pr2-merge-member) feat(anon-user): add merge member claim repair
3e1fd8ac (origin/anon-user) docs(anon-user): mark PR-1 done (e90b59df), codex resumes at PR-2
e90b59df feat(messages): session-scope messages — collapse vestigial multi-routing (anon-user PR-1)
```

Do not redo PR-1, PR-2, PR-3, or PR-4. Treat this as an acceptance/merge handoff.

## 1. What Codex completed

Original execution plan:

```text
docs/superpowers/plans/2026-06-21-anon-user-epic-codex-handoff.md
```

PR-1 was already completed by Claude before Codex started:

- Commit: `e90b59df`
- Scope: message session-scoping and removal of vestigial multi-routing.

Codex completed and locally merged these onto `anon-user`:

- PR-2: `Session.merge_member` plus durable anon merge claim/repair scaffold.
  - Feature commit: `048c82c3`
  - Merge commit: `b8860f0a`
- PR-3: `MessageStore.relabel_identity/3` plus `AnonCookie.verify_any/1`.
  - Feature commit: `2fab9302`
  - Merge commit: `c8a18fde`
- PR-4: `EzagentWeb.Socialware.AnonTakeover` plus the single post-auth hook.
  - Feature commit: `3eb6d3ea`
  - Merge commit: `561fe0a1`

## 2. PR-4 implementation notes

Important files:

- `apps/ezagent_web/lib/ezagent_web/socialware/anon_takeover.ex`
- `apps/ezagent_web/lib/ezagent_web/session_principal.ex`
- `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex`
- `apps/ezagent_web/test/ezagent_web/socialware/anon_takeover_test.exs`

PR-4 behavior:

- `SessionPrincipal.put/3` is the single post-auth hook shared by credentials login, magic-link
  login, and registration completion.
- The hook calls `EzagentWeb.Socialware.AnonTakeover.maybe_takeover/2`.
- Authority is signed-cookie possession plus `AnonBinding` confirmation through
  `AnonCookie.verify_any/1`.
- Takeover flow:
  1. verify signed anon cookie and matching binding;
  2. claim binding for merge;
  3. provision join authority for the confirmed user;
  4. dispatch `session.merge_member`;
  5. call `MessageStore.relabel_identity/3`;
  6. mount confirmed participation caps;
  7. verify anon is gone and confirmed user is member;
  8. retire anon user and binding;
  9. clear `socialware_anon` cookie on success.
- No `:takeover` cap was added.
- No new `system://` grant path was added.
- Runtime capability registration now includes `:merge_member`.

## 3. Verification already run by Codex

Focused PR-4 regression:

```bash
mix test \
  apps/ezagent_web/test/ezagent_web/socialware/anon_takeover_test.exs \
  apps/ezagent_web/test/ezagent_web/socialware/anon_cookie_test.exs \
  apps/ezagent_web/test/ezagent_web/session_principal_test.exs \
  apps/ezagent_web/test/ezagent_web/controllers/socialware/chat_feed_controller_test.exs \
  apps/ezagent_domain_session/test/ezagent/behavior/chat_test.exs
```

Result:

- `ezagent_domain_session`: 37 tests, 0 failures.
- `ezagent_web`: 36 tests, 0 failures.

URI-query scan tests after a precommit finding:

```bash
mix test \
  apps/ezagent_core/test/ezagent/uri_query/scan_test.exs \
  apps/ezagent_core/test/mix/tasks/ezagent.uri_query.scan_test.exs
```

Result: 17 tests, 0 failures.

Required gates:

```bash
mix ezagent.check_invariants
mix ezagent.arch.scan
mix ezagent.doc.scan
mix ezagent.caps.audit --strict
mix ezagent.check_invariants.lifecycle
```

Results:

- `check_invariants`: pass.
- `arch.scan`: pass, including `oversized_modules_gt_1000 count=3 cap=3`.
- `doc.scan`: pass.
- `caps.audit --strict`: pass, 37 Behavior modules, 0 missing `data_owner/1`.
- `check_invariants.lifecycle`: pass.

P13/cap invariant bundle:

```bash
mix test \
  apps/ezagent_core/test/invariants/cap_check_only_at_chokepoint_test.exs \
  apps/ezagent_core/test/invariants/system_principal_elimination_test.exs \
  apps/ezagent_core/test/invariants/no_unowned_system_principal_grant_test.exs \
  apps/ezagent_core/test/invariants/no_admin_caps_fallback_test.exs \
  apps/ezagent_core/test/invariants/no_wildcard_system_principals_test.exs \
  apps/ezagent_core/test/invariants/predicate_a_root_check_test.exs \
  apps/ezagent_core/test/invariants/grant_dispatch_chokepoint_test.exs \
  apps/ezagent_core/test/invariants/caps_data_owner_invariant_test.exs \
  apps/ezagent_core/test/ezagent/system_principal_catalog_action_audit_test.exs \
  --max-cases 1
```

Result: 38 tests, 0 failures.

Scoped formatting:

```bash
mix format --check-formatted \
  apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex \
  apps/ezagent_web/lib/ezagent_web/session_principal.ex \
  apps/ezagent_web/lib/ezagent_web/socialware/anon_takeover.ex \
  apps/ezagent_web/test/ezagent_web/socialware/anon_takeover_test.exs
```

Result: pass.

`mix precommit`:

- Codex ran `mix precommit` after fixing a real PR-4 URI-query scan violation.
- It exited nonzero only because of an existing broad-concurrency SQLite busy:

```text
apps/ezagent_domain_session/test/ezagent_domain_instance_message/uri_query_resolvers_test.exs:40
** (Exqlite.Error) Database busy
```

- The failing file passed when rerun serially:

```bash
mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/uri_query_resolvers_test.exs --max-cases 1
```

Result: 12 tests, 0 failures.

## 4. Agent-browser E2E already run

Codex ran a disposable local Phoenix server on port `4014`, then used `agent-browser` sessions for
the three login paths.

Passed browser paths:

- Credentials:
  - anon opens `/socialware/chat?...`;
  - `socialware_anon` cookie appears;
  - login through `/login/credentials?workspace=team-alpha`;
  - final URL is `/sessions`;
  - `socialware_anon` is cleared.
- Magic link:
  - anon opens `/socialware/chat?...`;
  - `socialware_anon` cookie appears;
  - open `/auth/magic/<token>`;
  - final URL is `/sessions`;
  - `socialware_anon` is cleared.
- Registration:
  - anon opens `/socialware/chat?...`;
  - magic-link onboarding to `/onboarding/workspace`;
  - join `team-alpha`;
  - complete registration;
  - final URL is `/sessions`;
  - `socialware_anon` is cleared.

Backend verifier also passed for all three E2E sessions:

```text
credentials: converged confirmed=entity://team-alpha/user/pr4-cred-782
magic_link: converged confirmed=entity://team-alpha/user/pr4-magic-782
registration: converged confirmed=entity://team-alpha/user/pr4-reg-782
```

The verifier checked durable convergence, including confirmed membership and zero remaining anon
bindings for those E2E sessions.

## 5. Issue #872 status

Codex read issue #872 before merging PR-4. At that time it only contained prior PR-2 and PR-3
status comments; there were no new PR-4 findings/comments to address.

Codex attempted to post a PR-4 status comment, but the local approval system blocked the external
GitHub write as requiring explicit user approval. Claude should post the PR-4 status comment if
that is still desired.

Suggested issue #872 comment:

```text
PR-4 status: implemented and merged to anon-user locally as merge commit 561fe0a1 after feature
commit 3eb6d3ea. Checked this issue before merge; there were no new PR-4 findings/comments to
address.

Implemented:
- EzagentWeb.Socialware.AnonTakeover orchestrates signed-cookie verified anon takeover after
  confirmed login.
- SessionPrincipal.put/3 is the single post-auth hook used by credentials, magic-link, and
  registration completion paths.
- Takeover uses Session.merge_member, MessageStore.relabel_identity/3, confirmed participation-cap
  mounting, convergence verification, and anon user/binding retirement.
- No :takeover cap or system:// grant path added.

Verification:
- PR-4 focused tests: PASS (37 domain_session + 36 web tests)
- URI-query scan tests: PASS (17 tests)
- mix ezagent.check_invariants: PASS
- mix ezagent.arch.scan: PASS
- mix ezagent.doc.scan: PASS
- mix ezagent.caps.audit --strict: PASS (0 missing data_owner/1)
- cap/p13 invariant bundle: PASS (38 tests)
- mix ezagent.check_invariants.lifecycle: PASS
- agent-browser E2E: PASS for credentials, magic-link, and registration completion paths.
- Backend E2E verifier: PASS for credentials, magic_link, and registration durable convergence.

mix precommit was run after fixing the PR-4 URI-query scan violation. It exited nonzero only on an
existing broad-concurrency SQLite busy in
apps/ezagent_domain_session/test/ezagent_domain_instance_message/uri_query_resolvers_test.exs:40;
the failing file rerun serially with --max-cases 1 passed (12 tests, 0 failures).
```

## 6. Claude acceptance checklist

Start from the local `anon-user` branch:

```bash
cd /Users/h2oslabs/Workspace/esr-ng/.worktrees/alias
git status --short --branch
git log --oneline -8 --decorate
```

Then:

1. Read the source plan and final design:

```text
docs/superpowers/plans/2026-06-21-anon-user-epic-codex-handoff.md
docs/superpowers/specs/2026-06-21-anon-login-merge-FINAL-design.md
```

2. Confirm no open PR-4 findings in issue #872:

```bash
gh issue view 872 --comments --repo ezagent42/ezagent
```

3. Re-run the acceptance gate you require before publication. Minimum recommended:

```bash
mix test \
  apps/ezagent_web/test/ezagent_web/socialware/anon_takeover_test.exs \
  apps/ezagent_web/test/ezagent_web/socialware/anon_cookie_test.exs \
  apps/ezagent_web/test/ezagent_web/session_principal_test.exs \
  apps/ezagent_web/test/ezagent_web/controllers/socialware/chat_feed_controller_test.exs \
  apps/ezagent_domain_session/test/ezagent/behavior/chat_test.exs

mix ezagent.check_invariants
mix ezagent.arch.scan
mix ezagent.doc.scan
mix ezagent.caps.audit --strict
mix ezagent.check_invariants.lifecycle

mix test \
  apps/ezagent_core/test/invariants/cap_check_only_at_chokepoint_test.exs \
  apps/ezagent_core/test/invariants/system_principal_elimination_test.exs \
  apps/ezagent_core/test/invariants/no_unowned_system_principal_grant_test.exs \
  apps/ezagent_core/test/invariants/no_admin_caps_fallback_test.exs \
  apps/ezagent_core/test/invariants/no_wildcard_system_principals_test.exs \
  apps/ezagent_core/test/invariants/predicate_a_root_check_test.exs \
  apps/ezagent_core/test/invariants/grant_dispatch_chokepoint_test.exs \
  apps/ezagent_core/test/invariants/caps_data_owner_invariant_test.exs \
  apps/ezagent_core/test/ezagent/system_principal_catalog_action_audit_test.exs \
  --max-cases 1
```

4. Re-run agent-browser E2E if you need independent browser evidence.

5. If all acceptance gates are satisfactory, publish and merge according to repo policy:
   - push local `anon-user` to `origin/anon-user`;
   - open/review a final PR from `anon-user` into the intended target branch, most likely `main`;
   - merge only after confirming the target branch and CI/review requirements.

Do not merge directly to `main` unless that is explicitly the repo's intended process for this
epic.

## 7. Paste prompt for Claude

```text
You are taking over the ezagent anon-user epic after Codex completed PR-2, PR-3, and PR-4 locally.
Your job is independent acceptance review, issue-log closure, and final publication/merge.

Worktree:
  /Users/h2oslabs/Workspace/esr-ng/.worktrees/alias

Start here:
  cd /Users/h2oslabs/Workspace/esr-ng/.worktrees/alias
  git status --short --branch
  git log --oneline -8 --decorate

Expected branch state:
  local branch anon-user, clean.
  Implementation merge commit 561fe0a1 Merge PR-4 anon takeover hook is reachable from HEAD.
  HEAD may be a docs-only handoff commit created after 561fe0a1.

Do not redo implementation. PR-1 was already done by Claude at e90b59df. Codex completed and
locally merged:
  PR-2 feature 048c82c3, merge b8860f0a
  PR-3 feature 2fab9302, merge c8a18fde
  PR-4 feature 3eb6d3ea, merge 561fe0a1

Read first:
  docs/superpowers/handoffs/2026-06-21-anon-user-claude-acceptance-handoff.md
  docs/superpowers/plans/2026-06-21-anon-user-epic-codex-handoff.md
  docs/superpowers/specs/2026-06-21-anon-login-merge-FINAL-design.md

Then inspect the PR-4 diff and acceptance-critical files:
  apps/ezagent_web/lib/ezagent_web/socialware/anon_takeover.ex
  apps/ezagent_web/lib/ezagent_web/session_principal.ex
  apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex
  apps/ezagent_web/test/ezagent_web/socialware/anon_takeover_test.exs

Acceptance requirements:
  - signed-cookie possession + AnonBinding confirm are required;
  - all three login paths use the single SessionPrincipal.put/3 post-auth hook;
  - takeover dispatches session.merge_member, relabels messages, mounts confirmed caps, verifies
    convergence, retires anon user + binding, and clears socialware_anon;
  - no :takeover cap;
  - no system:// grant path;
  - non-possessor cannot trigger takeover.

Before publication, read issue #872:
  gh issue view 872 --comments --repo ezagent42/ezagent

If there are new actionable findings, fix them before merge. If not, post the PR-4 status comment
from the handoff.

Re-run the acceptance gates you require. Minimum:
  mix test apps/ezagent_web/test/ezagent_web/socialware/anon_takeover_test.exs apps/ezagent_web/test/ezagent_web/socialware/anon_cookie_test.exs apps/ezagent_web/test/ezagent_web/session_principal_test.exs apps/ezagent_web/test/ezagent_web/controllers/socialware/chat_feed_controller_test.exs apps/ezagent_domain_session/test/ezagent/behavior/chat_test.exs
  mix ezagent.check_invariants
  mix ezagent.arch.scan
  mix ezagent.doc.scan
  mix ezagent.caps.audit --strict
  mix ezagent.check_invariants.lifecycle
  mix test apps/ezagent_core/test/invariants/cap_check_only_at_chokepoint_test.exs apps/ezagent_core/test/invariants/system_principal_elimination_test.exs apps/ezagent_core/test/invariants/no_unowned_system_principal_grant_test.exs apps/ezagent_core/test/invariants/no_admin_caps_fallback_test.exs apps/ezagent_core/test/invariants/no_wildcard_system_principals_test.exs apps/ezagent_core/test/invariants/predicate_a_root_check_test.exs apps/ezagent_core/test/invariants/grant_dispatch_chokepoint_test.exs apps/ezagent_core/test/invariants/caps_data_owner_invariant_test.exs apps/ezagent_core/test/ezagent/system_principal_catalog_action_audit_test.exs --max-cases 1

Codex also ran mix precommit. It exited nonzero only on an existing broad-concurrency SQLite busy
in apps/ezagent_domain_session/test/ezagent_domain_instance_message/uri_query_resolvers_test.exs:40;
that file passed serially with:
  mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/uri_query_resolvers_test.exs --max-cases 1

If acceptance is green, push local anon-user to origin/anon-user and open/review/merge the final PR
from anon-user into the intended target branch, most likely main. Confirm the target branch and repo
merge policy before merging. Do not bypass CI/review requirements.
```
