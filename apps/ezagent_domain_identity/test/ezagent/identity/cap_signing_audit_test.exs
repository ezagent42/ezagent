defmodule Ezagent.Identity.CapSigningAuditTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Identity.{CapQuarantine, CapSigningAudit, RecipeCapBinding}
  alias EzagentCore.Repo

  import EzagentDomainIdentity.CapSigningTestHelpers

  test "dual-read never turns an unsigned authorizer into an audit false zero" do
    holder = unique_user("audit-dual-read")
    unsigned = raw_identity_cap(holder)

    assert Ezagent.Cap.verify_for(unsigned, holder)
    refute Ezagent.Cap.signed_and_valid?(unsigned, holder)

    report =
      CapSigningAudit.scan_entries(
        %{
          users_caps_json: [entry(:users_caps_json, holder, unsigned)],
          kind_snapshots: [],
          recipe_cap_bindings: [],
          cap_quarantine: []
        },
        [Ezagent.Identity.CapReissuePolicy]
      )

    assert report.totals.unsigned_authorizer == 1
    assert report.unsigned_by_class == %{identity_self: 1}
    refute CapSigningAudit.clean?(report)
  end

  test "classifies four sources, sentinels, and only open quarantine rows" do
    user = unique_user("audit-user")
    agent = unique_agent("audit-agent")
    signed = issue!(user, raw_identity_cap(user), {:admin, Ezagent.Entity.User.admin_uri()})
    unsigned = raw_identity_cap(agent)
    sentinel = Capability.cap(:session, Ezagent.ActionSet.Session, :send)

    report =
      CapSigningAudit.scan_entries(
        %{
          users_caps_json: [entry(:users_caps_json, user, signed)],
          kind_snapshots: [entry(:kind_snapshots, agent, unsigned)],
          recipe_cap_bindings: [entry(:recipe_cap_bindings, user, sentinel)],
          cap_quarantine: [
            %{source: :cap_quarantine, status: :open, reason: ":no_resolver"},
            %{source: :cap_quarantine, status: :resolved, reason: ":fixed"}
          ]
        },
        [Ezagent.Identity.CapReissuePolicy]
      )

    assert report.totals == %{
             signed: 1,
             unsigned_authorizer: 1,
             sentinel_excluded: 1,
             open_quarantined: 1
           }

    assert report.unsigned_by_source == %{kind_snapshots: 1}
    assert report.open_quarantine_by_reason == %{":no_resolver" => 1}
    refute CapSigningAudit.clean?(report)
  end

  test "collect_entries reads users, latest identity snapshots, bindings, and quarantine" do
    user = unique_user("audit-collect-user")
    agent = unique_agent("audit-collect-agent")
    user_cap = raw_identity_cap(user)
    snapshot_cap = raw_identity_cap(agent)
    binding_cap = %{raw_identity_cap(agent) | behavior: Ezagent.ActionSet.ConfigEvolve}

    create_legacy_user!(user, nil, [user_cap])
    insert_snapshot!(agent, snapshot_cap)
    insert_binding!(agent, binding_cap)
    assert :ok = CapQuarantine.record(agent, snapshot_cap, :identity_self, :no_resolver)

    entries = CapSigningAudit.collect_entries()

    assert contains_cap?(entries.users_caps_json, user, user_cap)
    assert contains_cap?(entries.kind_snapshots, agent, snapshot_cap)
    assert contains_cap?(entries.recipe_cap_bindings, agent, binding_cap)

    assert Enum.any?(entries.cap_quarantine, fn row ->
             row.status == :open and row.holder_uri == URI.to_string(agent) and
               row.reason =~ "no_resolver"
           end)
  end

  test "a completely signed inventory with no open quarantine is strict-clean" do
    holder = unique_user("audit-clean")
    signed = issue!(holder, raw_identity_cap(holder), {:admin, Ezagent.Entity.User.admin_uri()})

    report =
      CapSigningAudit.scan_entries(
        %{
          users_caps_json: [entry(:users_caps_json, holder, signed)],
          kind_snapshots: [],
          recipe_cap_bindings: [],
          cap_quarantine: [%{source: :cap_quarantine, status: :resolved, reason: ":fixed"}]
        },
        [Ezagent.Identity.CapReissuePolicy]
      )

    assert CapSigningAudit.clean?(report)
  end

  test "a malformed tombstoned binding is not counted as live unsigned authority" do
    agent = unique_agent("audit-tombstoned-malformed")
    now = DateTime.utc_now()

    %RecipeCapBinding{
      agent_uri: URI.to_string(agent),
      workspace_uri: "workspace://team-alpha",
      recipe_name: "retired-fixture",
      issuer_uri: URI.to_string(Ezagent.Entity.User.admin_uri()),
      artifacts: %{"not_caps" => :malformed},
      content_hash: "retired-malformed",
      version: 1,
      tombstoned_at: now,
      inserted_at: now,
      updated_at: now
    }
    |> Repo.insert!()

    entries = CapSigningAudit.collect_entries()
    report = CapSigningAudit.scan_entries(entries, [Ezagent.Identity.CapReissuePolicy])

    refute Enum.any?(entries.recipe_cap_bindings, &(&1.holder_uri == URI.to_string(agent)))
    assert report.totals.unsigned_authorizer == 0
    assert report.unsigned_by_source == %{}
  end

  defp entry(source, holder, cap), do: %{source: source, holder_uri: holder, cap: cap}

  defp unique_user(prefix) do
    Ezagent.URI.user("team-alpha", "#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp unique_agent(prefix) do
    Ezagent.URI.agent("team-alpha", "#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp raw_identity_cap(holder) do
    %Capability{
      kind: if(holder.path =~ "/agent/", do: :agent, else: :user),
      behavior: Ezagent.ActionSet.Identity,
      action: :list_caps,
      instance: holder,
      workspace_uri: Ezagent.URI.workspace("team-alpha"),
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp insert_snapshot!(holder, cap) do
    state = %{identity: %{state: %{caps: MapSet.new([cap])}, transients: %{}}}

    {:ok, _row} =
      Ezagent.Test.SnapshotFixtures.upsert_kind_snapshot(
        URI.to_string(holder),
        "agent",
        :erlang.term_to_binary(state),
        1,
        "workspace://team-alpha"
      )
  end

  defp insert_binding!(holder, cap) do
    now = DateTime.utc_now()

    %RecipeCapBinding{
      agent_uri: URI.to_string(holder),
      workspace_uri: "workspace://team-alpha",
      recipe_name: "audit-fixture",
      issuer_uri: URI.to_string(Ezagent.Entity.User.admin_uri()),
      artifacts: %{"caps" => [Capability.to_map(cap)]},
      content_hash: "audit-fixture",
      version: 1,
      inserted_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp contains_cap?(entries, holder, expected) do
    Enum.any?(entries, fn
      %{holder_uri: ^holder, cap: cap} -> cap == expected
      _entry -> false
    end)
  end
end
