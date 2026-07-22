defmodule Ezagent.Session.MembersAreCapHoldersInvariantTest do
  @moduledoc "M-8 ordering proof: backfill and gate precede roster eviction."

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Session.Reconcile
  alias Ezagent.Session.MemberCapMigration

  test "T4: migration gate covers the legacy roster before strict reconciliation" do
    owner = confirmed_user("owner")
    member = confirmed_user("member")
    session = seed_legacy_session(owner, member)
    persisted = %{member => %{online: false}}

    assert {:error, {:uncovered_member_caps, uncovered}} = MemberCapMigration.gate()
    assert uncovered >= 1

    # Strict reconcile would intentionally drop an unbackfilled legacy member;
    # this is the executable reason the migration ordering is load-bearing.
    refute Map.has_key?(Reconcile.reconcile_after_load(session, persisted), member)

    report = MemberCapMigration.migrate(false)
    assert report.members_granted >= 1
    assert :ok = MemberCapMigration.gate()

    reconciled = Reconcile.reconcile_after_load(session, persisted)
    assert Map.has_key?(reconciled, member)

    assert Enum.all?(
             Map.keys(reconciled),
             &Reconcile.member_cap_holder?(&1, session, Ezagent.Capability.workspace_of(session))
           )
  end

  defp confirmed_user(prefix) do
    uri = Ezagent.URI.user("system", "m8-#{prefix}-#{unique()}")
    assert {:ok, _row} = Ezagent.Users.create(uri, "pw-#{unique()}", [])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp seed_legacy_session(owner, member) do
    session = Ezagent.URI.session("system", :default, "m8-legacy-#{unique()}")

    :ok =
      Ezagent.Test.SnapshotFixtures.save_kind_snapshot(
        session,
        Ezagent.Entity.Session,
        %{
          kind_base: %{
            state: %{behaviors: Ezagent.Entity.Session.behaviors()},
            transients: %{}
          },
          session: %{
            state: %{members: %{member => %{online: false}}, owner_uri: owner},
            transients: %{}
          }
        }
      )

    session
  end

  defp unique, do: System.unique_integer([:positive])
end
