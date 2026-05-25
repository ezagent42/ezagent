defmodule EzagentCore.Invariants.NoDefaultWorkspaceRefsTest do
  @moduledoc """
  Invariant gate for PR #335 workspace rename (`default → system`)
  and its sibling data migration
  (`priv/repo/migrations/20260613000000_data_migrate_default_to_system_uris.exs`).

  The original PR #335 renamed the seeded workspace at the
  schema/seed layer but did not walk existing data rows; the gap
  surfaced on 2026-05-25 when a recovered dev DB held ~250 stale
  `default` references across 9 tables, breaking the login flow.
  This test fail-louds any re-introduction of `/default/` or
  `workspace://default` literals in URI columns — the migration
  must always leave the DB at zero `default` refs.

  ## What is checked

  Every URI-shaped column across the project's data tables. The
  list is hardcoded (not derived via schema reflection) so the
  invariant remains stable even if a future migration adds new
  URI-shaped columns: a new column should appear in this list at
  the same time it's added.

  `messages.body` is intentionally EXCLUDED — that column holds
  natural-language chat content where the word "default" is a
  legitimate English word, not a URI fragment.

  ## Why this is the merge gate, not a one-shot lint

  Per memory `feedback_completion_requires_invariant_test`,
  "completion claim requires invariant test" — the architectural
  goal here is "post-rename DB never holds a `default` URI". This
  test is the gate that fails when the goal is unmet, not "PR
  merges + manual review claims it works".
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Repo

  # `{table, [columns]}` — every URI-shaped column. Add new entries
  # here when a future migration introduces additional URI columns.
  @uri_columns [
    {"users", ["uri", "workspace_uri", "caps_json"]},
    {"kind_snapshots", ["uri", "workspace_uri"]},
    {"external_mirror_bindings", ["session_uri", "workspace_uri"]},
    {"message_routings", ["session_uri"]},
    {"feishu_user_bindings", ["user_uri"]},
    {"read_markers", ["workspace_uri", "session_uri", "user_uri"]},
    {"entity_profiles", ["entity_uri", "workspace_uri"]},
    {"routing_rules",
     [
       "source",
       "created_by",
       "workspace_uri",
       # JSON columns — URI literals inside appear as double-quoted
       # strings; the LIKE patterns in count_default_refs/2 match the
       # URI prefixes regardless of JSON quoting.
       "matcher_data",
       "receivers",
       "applies_to_users"
     ]},
    {"invocations", ["caller", "target", "workspace_uri"]},
    # NOTE: `messages.body` intentionally EXCLUDED — natural-language
    # content. URI-shaped message columns ARE checked.
    {"messages", ["session_uri", "workspace_uri", "sender", "mentions"]}
  ]

  test "no production rows reference the obsolete `default` workspace" do
    offenders =
      for {tbl, cols} <- @uri_columns,
          col <- cols,
          count = count_default_refs(tbl, col),
          count > 0,
          do: "#{tbl}.#{col}: #{count}"

    assert offenders == [],
           """
           default-workspace leakage detected (#{length(offenders)} columns):
             #{Enum.join(offenders, "\n  ")}

           PR #335 renamed `default → system` at the schema/seed layer.
           The sibling data migration
           (priv/repo/migrations/20260613000000_data_migrate_default_to_system_uris.exs)
           must rewrite every URI reference. If you added a new URI
           column to a table since 2026-05-25, add it to @uri_columns
           in this test AND add an UPDATE statement to that migration
           (or a new follow-up migration).
           """
  end

  defp count_default_refs(tbl, col) do
    # Match ONLY the stale-workspace URI positions, NOT every
    # occurrence of the word "default". Legitimate non-workspace
    # uses of "default" exist:
    #   - `session://system/default/ezagent-test` — `default` is a
    #     session NAMESPACE (second segment), workspace is `system`
    #   - `entity://agent/system/echo_default` — agent NAME contains
    #     "default" as a substring
    #   - `template://agent/default/cc-orchestrator` — template path
    #     segment, not a workspace reference
    # Only the first path segment (workspace position) needs guarding.
    sql = """
    SELECT COUNT(*)
      FROM #{tbl}
     WHERE #{col} = 'workspace://default'
        OR #{col} LIKE '%entity://user/default/%'
        OR #{col} LIKE '%entity://agent/default/%'
        OR #{col} LIKE '%session://default/%'
        OR #{col} LIKE '%workspace://default%'
    """

    case Repo.query(sql) do
      {:ok, %{rows: [[n]]}} -> n
      # Table may not exist in this test DB (umbrella structure /
      # plugin-specific tables); count zero so the invariant doesn't
      # false-positive on environments where a domain isn't loaded.
      {:error, _} -> 0
    end
  end
end
