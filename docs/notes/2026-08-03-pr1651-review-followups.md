# PR #1651 review follow-ups

Deferred on 2026-08-03 so the current worktree can be started for manual testing:

1. Ensure API-key credential deletion/expiry has a production reconciliation trigger that returns a joined gated role to `pending_auth`.
2. Prevent a retained default credential-source pointer to a retired agent from allowing repair/materialization to silently create a replacement member.
3. Make joined-agent reconciliation recoverable when the working-copy write and member cleanup/retirement do not all succeed.

Resolution status after the 2026-08-03 follow-up work:

1. Joined admissions are periodically revalidated in production, including the frozen
   backend profile required by profile-driven API-key credentials.
2. An authentication-failed `pending_auth` admission is forced to remain deferred, so
   a retained pointer cannot silently materialize a replacement member.
3. The sweeper retries interrupted reconciliation rows that retain their attempt and
   provisional-agent evidence until cleanup and the final working-copy write converge.

Final independent re-review completed with no findings (no Critical, Important, or
Minor issues).
