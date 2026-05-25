defmodule EzagentCore.Repo.Migrations.DataMigrateDefaultToSystemUris do
  @moduledoc """
  Data-side completion of PR #335 (workspace rename `default → system`).

  PR #335 renamed the seeded `default` workspace to `system` at the
  schema/seed layer but did NOT walk through existing data rows to
  rewrite URI references. On 2026-05-25 a recovered dev DB (post
  SQLite `.recover` from a SIGTERM-induced corruption) surfaced this
  gap: `users.uri` still held `entity://user/default/linyilun`,
  `kind_snapshots.uri` held `session://default/...`, and ~250
  `invocations` rows referenced the `default` workspace — none of
  which the running phx code (post-rename) could resolve. Login
  failed with "URI or credentials invalid" because the bare-handle
  canonicalize-into-system path could not find the user row.

  Allen ran the equivalent SQL by hand to unblock the dev DB at
  17:12. This migration encodes that transaction as a permanent fix
  so:

  - Fresh dev clones whose seed DB contains pre-rename data are
    migrated forward automatically on `mix ecto.migrate`.
  - The accompanying invariant test
    (`apps/ezagent_core/test/invariants/no_default_workspace_refs_test.exs`)
    fail-louds against any re-introduction of `default` URI refs.

  ## Idempotence

  Every UPDATE is shaped so a re-run on an already-migrated DB is a
  no-op: `REPLACE(col, 'old', 'new')` on a column that no longer
  contains `'old'` returns the same string; `UPDATE col = 'new' WHERE
  col = 'old'` matches zero rows on the second run.

  ## Intentional exclusions

  `messages.body` is NOT touched — that column holds natural-language
  chat content that may legitimately contain the word "default" in
  prose. The migration only rewrites URI-shaped columns.

  ## Rollback

  `down/0` is intentionally a no-op. Rolling back to pre-rename URIs
  would put the DB in a state the post-rename code cannot resolve,
  and the original `default` workspace row is no longer seeded.
  Operators needing a true rollback should restore from a pre-PR-335
  DB backup (e.g. the dev backup at
  `~/.ezagent/default/db/ezagent_core.db.bak-20260525-154025`).

  Issue #342 sibling fix — see PR description for the let-it-crash
  + invariant-test discussion.
  """
  use Ecto.Migration

  def up do
    # users.uri: entity://user/default/X -> entity://user/system/X
    execute """
    UPDATE users
       SET uri = REPLACE(uri, 'entity://user/default/', 'entity://user/system/')
     WHERE uri LIKE 'entity://user/default/%'
    """

    execute """
    UPDATE users
       SET workspace_uri = 'workspace://system'
     WHERE workspace_uri = 'workspace://default'
    """

    execute """
    UPDATE users
       SET caps_json = REPLACE(caps_json, 'workspace://default', 'workspace://system')
     WHERE caps_json LIKE '%workspace://default%'
    """

    # kind_snapshots.uri: entity/session/workspace variants
    execute """
    UPDATE kind_snapshots
       SET uri = REPLACE(uri, 'entity://user/default/', 'entity://user/system/')
     WHERE uri LIKE 'entity://user/default/%'
    """

    execute """
    UPDATE kind_snapshots
       SET uri = REPLACE(uri, 'entity://agent/default/', 'entity://agent/system/')
     WHERE uri LIKE 'entity://agent/default/%'
    """

    execute """
    UPDATE kind_snapshots
       SET uri = REPLACE(uri, 'session://default/', 'session://system/')
     WHERE uri LIKE 'session://default/%'
    """

    execute """
    UPDATE kind_snapshots
       SET uri = 'workspace://system'
     WHERE uri = 'workspace://default'
    """

    execute """
    UPDATE kind_snapshots
       SET workspace_uri = 'workspace://system'
     WHERE workspace_uri = 'workspace://default'
    """

    # external_mirror_bindings
    execute """
    UPDATE external_mirror_bindings
       SET session_uri = REPLACE(session_uri, 'session://default/', 'session://system/')
     WHERE session_uri LIKE 'session://default/%'
    """

    execute """
    UPDATE external_mirror_bindings
       SET workspace_uri = 'workspace://system'
     WHERE workspace_uri = 'workspace://default'
    """

    # message_routings
    execute """
    UPDATE message_routings
       SET session_uri = REPLACE(session_uri, 'session://default/', 'session://system/')
     WHERE session_uri LIKE 'session://default/%'
    """

    # feishu_user_bindings
    execute """
    UPDATE feishu_user_bindings
       SET user_uri = REPLACE(user_uri, 'entity://user/default/', 'entity://user/system/')
     WHERE user_uri LIKE 'entity://user/default/%'
    """

    # read_markers
    execute """
    UPDATE read_markers
       SET workspace_uri = 'workspace://system'
     WHERE workspace_uri = 'workspace://default'
    """

    execute """
    UPDATE read_markers
       SET session_uri = REPLACE(session_uri, 'session://default/', 'session://system/')
     WHERE session_uri LIKE 'session://default/%'
    """

    execute """
    UPDATE read_markers
       SET user_uri = REPLACE(user_uri, 'entity://user/default/', 'entity://user/system/')
     WHERE user_uri LIKE 'entity://user/default/%'
    """

    # routing_rules.source
    execute """
    UPDATE routing_rules
       SET source = REPLACE(source, 'session://default/', 'session://system/')
     WHERE source LIKE 'session://default/%'
    """

    execute """
    UPDATE routing_rules
       SET source = REPLACE(source, 'entity://user/default/', 'entity://user/system/')
     WHERE source LIKE 'entity://user/default/%'
    """

    execute """
    UPDATE routing_rules
       SET source = REPLACE(source, 'entity://agent/default/', 'entity://agent/system/')
     WHERE source LIKE 'entity://agent/default/%'
    """

    # invocations (caller, target, workspace_uri)
    execute """
    UPDATE invocations
       SET caller = REPLACE(caller, 'entity://user/default/', 'entity://user/system/')
     WHERE caller LIKE 'entity://user/default/%'
    """

    execute """
    UPDATE invocations
       SET caller = REPLACE(caller, 'entity://agent/default/', 'entity://agent/system/')
     WHERE caller LIKE 'entity://agent/default/%'
    """

    execute """
    UPDATE invocations
       SET target = REPLACE(target, 'entity://user/default/', 'entity://user/system/')
     WHERE target LIKE 'entity://user/default/%'
    """

    execute """
    UPDATE invocations
       SET target = REPLACE(target, 'entity://agent/default/', 'entity://agent/system/')
     WHERE target LIKE 'entity://agent/default/%'
    """

    execute """
    UPDATE invocations
       SET target = REPLACE(target, 'session://default/', 'session://system/')
     WHERE target LIKE 'session://default/%'
    """

    execute """
    UPDATE invocations
       SET workspace_uri = 'workspace://system'
     WHERE workspace_uri = 'workspace://default'
    """

    # entity_profiles — caught in static review of PR #343 (codex r1
    # was unreachable today due to API 529s; main-agent self-review
    # at 2026-05-25 ~17:55 audited every URI-shaped column across
    # the schema and added the four below).
    execute """
    UPDATE entity_profiles
       SET entity_uri = REPLACE(entity_uri, 'entity://user/default/', 'entity://user/system/')
     WHERE entity_uri LIKE 'entity://user/default/%'
    """

    execute """
    UPDATE entity_profiles
       SET entity_uri = REPLACE(entity_uri, 'entity://agent/default/', 'entity://agent/system/')
     WHERE entity_uri LIKE 'entity://agent/default/%'
    """

    execute """
    UPDATE entity_profiles
       SET workspace_uri = 'workspace://system'
     WHERE workspace_uri = 'workspace://default'
    """

    # routing_rules — additional URI-shaped columns beyond `source`.
    # `matcher_data` / `receivers` / `applies_to_users` are JSON; the
    # REPLACE-on-substring stays JSON-safe because URI literals
    # inside JSON are double-quoted strings — substituting a URI
    # prefix doesn't disturb structural punctuation.
    execute """
    UPDATE routing_rules
       SET created_by = REPLACE(created_by, 'entity://user/default/', 'entity://user/system/')
     WHERE created_by LIKE 'entity://user/default/%'
    """

    execute """
    UPDATE routing_rules
       SET created_by = REPLACE(created_by, 'entity://agent/default/', 'entity://agent/system/')
     WHERE created_by LIKE 'entity://agent/default/%'
    """

    execute """
    UPDATE routing_rules
       SET workspace_uri = 'workspace://system'
     WHERE workspace_uri = 'workspace://default'
    """

    execute """
    UPDATE routing_rules
       SET matcher_data = REPLACE(matcher_data, 'entity://user/default/', 'entity://user/system/')
     WHERE matcher_data LIKE '%entity://user/default/%'
    """

    execute """
    UPDATE routing_rules
       SET matcher_data = REPLACE(matcher_data, 'entity://agent/default/', 'entity://agent/system/')
     WHERE matcher_data LIKE '%entity://agent/default/%'
    """

    execute """
    UPDATE routing_rules
       SET matcher_data = REPLACE(matcher_data, 'session://default/', 'session://system/')
     WHERE matcher_data LIKE '%session://default/%'
    """

    execute """
    UPDATE routing_rules
       SET matcher_data = REPLACE(matcher_data, 'workspace://default', 'workspace://system')
     WHERE matcher_data LIKE '%workspace://default%'
    """

    execute """
    UPDATE routing_rules
       SET receivers = REPLACE(receivers, 'entity://user/default/', 'entity://user/system/')
     WHERE receivers LIKE '%entity://user/default/%'
    """

    execute """
    UPDATE routing_rules
       SET receivers = REPLACE(receivers, 'entity://agent/default/', 'entity://agent/system/')
     WHERE receivers LIKE '%entity://agent/default/%'
    """

    execute """
    UPDATE routing_rules
       SET receivers = REPLACE(receivers, 'session://default/', 'session://system/')
     WHERE receivers LIKE '%session://default/%'
    """

    execute """
    UPDATE routing_rules
       SET applies_to_users = REPLACE(applies_to_users, 'entity://user/default/', 'entity://user/system/')
     WHERE applies_to_users LIKE '%entity://user/default/%'
    """

    # messages — URI columns only, NOT body
    execute """
    UPDATE messages
       SET session_uri = REPLACE(session_uri, 'session://default/', 'session://system/')
     WHERE session_uri LIKE 'session://default/%'
    """

    execute """
    UPDATE messages
       SET workspace_uri = 'workspace://system'
     WHERE workspace_uri = 'workspace://default'
    """

    execute """
    UPDATE messages
       SET sender = REPLACE(sender, 'entity://user/default/', 'entity://user/system/')
     WHERE sender LIKE 'entity://user/default/%'
    """

    execute """
    UPDATE messages
       SET sender = REPLACE(sender, 'entity://agent/default/', 'entity://agent/system/')
     WHERE sender LIKE 'entity://agent/default/%'
    """

    execute """
    UPDATE messages
       SET mentions = REPLACE(mentions, 'entity://user/default/', 'entity://user/system/')
     WHERE mentions LIKE '%entity://user/default/%'
    """

    execute """
    UPDATE messages
       SET mentions = REPLACE(mentions, 'entity://agent/default/', 'entity://agent/system/')
     WHERE mentions LIKE '%entity://agent/default/%'
    """
  end

  def down do
    # See moduledoc — rollback intentionally not provided. The
    # post-rename code cannot resolve `workspace://default` /
    # `entity://user/default/...` URIs; restoring those rows leaves
    # the DB in an unrunnable state.
    :ok
  end
end
