defmodule Ezagent.Credential.GrantRowTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Credential.GrantRow

  # Seed a durable snapshot row so `source_exists?/1` (SnapshotStore.latest/1) passes.
  defp seed_source(uri_str) do
    {:ok, _} = Ezagent.SnapshotStore.write(uri_str, %{}, kind_type: :agent)
    uri_str
  end

  test "insert + get a grant; version starts at 1; agent_uri is unique" do
    attrs = %{
      agent_uri: "entity://team-a/agent/worker1",
      credential_source_uri: "entity://team-a/agent/alice-base",
      approved_by: "entity://team-a/user/alice",
      approved_scope: "entity://team-a/agent/alice-base",
      workspace_uri: "workspace://wrong",
      version: 1
    }

    assert {:ok, row} = GrantRow.insert(attrs)
    assert row.version == 1
    assert row.workspace_uri == "workspace://team-a"
    assert GrantRow.get_for_agent("entity://team-a/agent/worker1").id == row.id
    # one active grant per agent → second insert for same agent_uri collides
    assert {:error, _} = GrantRow.insert(attrs)
  end

  test "revoke bumps version and stamps revoked_at" do
    {:ok, row} =
      GrantRow.insert(%{
        agent_uri: "entity://team-a/agent/w2",
        credential_source_uri: "s",
        approved_by: "u",
        approved_scope: "s",
        version: 1
      })

    assert {:ok, revoked} = GrantRow.revoke(row.agent_uri)
    assert revoked.version == row.version + 1
    assert revoked.revoked_at != nil
  end

  test "fetch_for_materialize fails for a revoked grant, returns source+version when active" do
    source = seed_source("entity://team-a/agent/alice-base")

    {:ok, g} =
      GrantRow.insert(%{
        agent_uri: "entity://team-a/agent/m1",
        credential_source_uri: source,
        approved_by: "u",
        approved_scope: source,
        version: 1
      })

    assert {:ok, ^source, 1, incarnation_id} = GrantRow.fetch_for_materialize(g.agent_uri)
    assert incarnation_id == g.incarnation_id
    {:ok, _} = GrantRow.revoke(g.agent_uri)
    assert {:error, :revoked} = GrantRow.fetch_for_materialize(g.agent_uri)
  end

  test "fetch_for_materialize fails when source no longer exists" do
    {:ok, g} =
      GrantRow.insert(%{
        agent_uri: "entity://team-a/agent/m1b",
        credential_source_uri: "entity://team-a/agent/ghost",
        approved_by: "u",
        approved_scope: "entity://team-a/agent/ghost",
        version: 1
      })

    assert {:error, :source_not_found} = GrantRow.fetch_for_materialize(g.agent_uri)
  end

  test "fetch_for_materialize fails when approved_scope != the source (grant for A used for B)" do
    {:ok, g} =
      GrantRow.insert(%{
        agent_uri: "entity://team-a/agent/m2",
        credential_source_uri: "entity://team-a/agent/B",
        approved_by: "u",
        approved_scope: "entity://team-a/agent/A",
        version: 1
      })

    assert {:error, :scope_mismatch} = GrantRow.fetch_for_materialize(g.agent_uri)
  end

  test "revalidate_version! aborts when revoked AFTER the precheck (TOCTOU)" do
    {:ok, g} =
      GrantRow.insert(%{
        agent_uri: "entity://team-a/agent/m3",
        credential_source_uri: "s",
        approved_by: "u",
        approved_scope: "s",
        version: 1
      })

    assert :ok = GrantRow.revalidate_version!(g.agent_uri, g.incarnation_id, 1)
    # revoke bumps version + stamps
    {:ok, _} = GrantRow.revoke(g.agent_uri)

    assert {:error, :grant_changed} =
             GrantRow.revalidate_version!(g.agent_uri, g.incarnation_id, 1)
  end

  test "reapprove replaces a revoked grant and bumps version" do
    {:ok, g} =
      GrantRow.insert(%{
        agent_uri: "entity://team-a/agent/m4",
        credential_source_uri: "s",
        approved_by: "u",
        approved_scope: "s",
        version: 1
      })

    {:ok, _} = GrantRow.revoke(g.agent_uri)

    {:ok, re} =
      GrantRow.reapprove(%{
        agent_uri: g.agent_uri,
        credential_source_uri: "s2",
        approved_by: "u",
        approved_scope: "s2"
      })

    assert re.revoked_at == nil and re.version >= g.version + 2
    assert re.workspace_uri == "workspace://team-a"
  end

  # #201 PR-3 (R4) — the immutable grant-incarnation id is the ABA-safe
  # identity for compensating deletes.
  describe "incarnation-scoped delete" do
    test "insert mints an incarnation id" do
      {:ok, row} =
        GrantRow.insert(%{
          agent_uri: "entity://team-a/agent/inc1",
          credential_source_uri: "s",
          approved_by: "u",
          approved_scope: "s",
          version: 1
        })

      assert is_binary(row.incarnation_id)
    end

    test "a stale compensator cannot delete a reapproved row (reapprove re-incarnates)" do
      {:ok, g} =
        GrantRow.insert(%{
          agent_uri: "entity://team-a/agent/inc2",
          credential_source_uri: "s",
          approved_by: "u",
          approved_scope: "s",
          version: 1
        })

      {:ok, re} =
        GrantRow.reapprove(%{
          agent_uri: g.agent_uri,
          credential_source_uri: "s2",
          approved_by: "u",
          approved_scope: "s2"
        })

      refute re.incarnation_id == g.incarnation_id

      # The stale compensator holds the OLD incarnation: it must NOT delete
      # the new row.
      assert {:ok, :no_grant} = GrantRow.delete_incarnation(g.agent_uri, g.incarnation_id)

      assert Map.get(GrantRow.get_for_agent(g.agent_uri), :incarnation_id) ==
               re.incarnation_id

      # The CURRENT incarnation's owner can delete.
      assert {:ok, :deleted} = GrantRow.delete_incarnation(g.agent_uri, re.incarnation_id)
      assert GrantRow.get_for_agent(g.agent_uri) == nil
    end

    test "a stale compensator cannot delete a hard-delete + reinsert row (ABA)" do
      attrs = %{
        agent_uri: "entity://team-a/agent/inc3",
        credential_source_uri: "s",
        approved_by: "u",
        approved_scope: "s",
        version: 1
      }

      {:ok, first} = GrantRow.insert(attrs)
      {:ok, _} = GrantRow.delete(first.agent_uri)

      # Reinsert: version resets to 1 — URI+version looks identical to the
      # first row, but the incarnation differs.
      {:ok, second} = GrantRow.insert(attrs)
      assert second.version == 1
      refute second.incarnation_id == first.incarnation_id

      assert {:ok, :no_grant} =
               GrantRow.delete_incarnation(first.agent_uri, first.incarnation_id)

      assert Map.get(GrantRow.get_for_agent(first.agent_uri), :incarnation_id) ==
               second.incarnation_id

      assert {:ok, :deleted} =
               GrantRow.delete_incarnation(first.agent_uri, second.incarnation_id)

      assert GrantRow.get_for_agent(first.agent_uri) == nil
    end

    test "delete_incarnation is a no-op when no row exists" do
      assert {:ok, :no_grant} =
               GrantRow.delete_incarnation("entity://team-a/agent/ghost-inc", "nope")
    end
  end

  # #201-cred (codex r2 NEW-MEDIUM-4) — a legacy grant minted before the
  # incarnation column existed has `incarnation_id = NULL`; it must materialize
  # WITHOUT the revalidation raising `FunctionClauseError` on the nil incarnation.
  describe "legacy NULL-incarnation grant" do
    defp make_legacy_null_grant(agent_uri, source) do
      {:ok, _g} =
        GrantRow.insert(%{
          agent_uri: agent_uri,
          credential_source_uri: source,
          approved_by: "u",
          approved_scope: source,
          version: 1
        })

      # Simulate a pre-column row: NULL out the incarnation the insert minted.
      {:ok, _} =
        EzagentCore.Repo.query(
          "UPDATE credential_grants SET incarnation_id = NULL WHERE id = $1",
          [agent_uri]
        )

      GrantRow.get_for_agent(agent_uri)
    end

    test "fetch_for_materialize returns a nil incarnation for a legacy row" do
      source = seed_source("entity://team-a/agent/legacy-src-a")
      legacy = make_legacy_null_grant("entity://team-a/agent/legacy-a", source)
      assert legacy.incarnation_id == nil

      assert {:ok, ^source, 1, nil} = GrantRow.fetch_for_materialize(legacy.agent_uri)
    end

    test "revalidate_version! tolerates a nil incarnation (no FunctionClauseError)" do
      source = seed_source("entity://team-a/agent/legacy-src-b")
      legacy = make_legacy_null_grant("entity://team-a/agent/legacy-b", source)

      # Pre-fix: the `is_binary(incarnation_id)` guard left `nil` unmatched and
      # `revalidate_version!/3` raised `FunctionClauseError` mid-materialize.
      # Post-fix: the legacy row revalidates on (version, not-revoked,
      # generations-current) alone.
      assert :ok = GrantRow.revalidate_version!(legacy.agent_uri, nil, legacy.version)

      # A version mismatch on a legacy row is still a clean rejection, not a raise.
      assert {:error, :grant_changed} =
               GrantRow.revalidate_version!(legacy.agent_uri, nil, legacy.version + 5)
    end

    test "materialize_with_grant commits a legacy row without raising" do
      source = seed_source("entity://team-a/agent/legacy-src-c")
      legacy = make_legacy_null_grant("entity://team-a/agent/legacy-c", source)

      staging =
        Path.join(System.tmp_dir!(), "legacy-staging-#{System.unique_integer([:positive])}")

      src_dir = Path.join(System.tmp_dir!(), "legacy-src-#{System.unique_integer([:positive])}")
      File.mkdir_p!(staging)
      File.mkdir_p!(src_dir)

      on_exit(fn ->
        File.rm_rf(staging)
        File.rm_rf(src_dir)
      end)

      # Pre-fix this raised FunctionClauseError at the revalidation step; now it
      # runs the commit callback cleanly.
      assert {:ok, :committed} =
               Ezagent.Agent.Materializer.materialize_with_grant(%{
                 agent_uri: legacy.agent_uri,
                 staging: staging,
                 secret_relpaths: [],
                 source_dir_for: fn ^source -> {:ok, src_dir} end,
                 commit: fn {_version, nil} -> {:ok, :committed} end
               })
    end
  end
end
