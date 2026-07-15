defmodule Ezagent.Identity.CapQuarantineTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Identity.CapQuarantine

  test "upserts one open row and tombstones it on resolution" do
    holder =
      Ezagent.URI.new!(
        "entity://team-alpha/user/quarantine-#{System.unique_integer([:positive])}"
      )

    cap = raw_cap()

    assert :ok = CapQuarantine.record(holder, cap, :unknown, :no_resolver)
    assert :ok = CapQuarantine.record(holder, cap, :unknown, :still_no_resolver)

    assert [row] = CapQuarantine.list_open(holder)
    assert row.holder_uri == URI.to_string(holder)
    assert row.class == "unknown"
    assert row.reason =~ "still_no_resolver"
    assert row.status == :open

    assert :ok = CapQuarantine.close(holder, cap)
    assert CapQuarantine.list_open(holder) == []

    assert :ok = CapQuarantine.record(holder, cap, :unknown, :returned)
    assert [%{status: :open, closed_at: nil}] = CapQuarantine.list_open(holder)
  end

  test "the normal revoke handler tombstones an open row" do
    holder =
      Ezagent.URI.new!(
        "entity://team-alpha/user/quarantine-revoke-#{System.unique_integer([:positive])}"
      )

    cap = raw_cap()
    assert :ok = CapQuarantine.record(holder, cap, :unknown, :no_resolver)
    EzagentDomainIdentity.CapSigningTestHelpers.create_legacy_user!(holder, nil, [cap])

    ctx = %{
      caller: Ezagent.Entity.User.admin_uri(),
      self_uri: holder,
      caps: MapSet.new(),
      read: fn
        :caps, _default -> MapSet.new([cap])
        _key, default -> default
      end
    }

    assert {:ok, %{caps: []}, _effects} =
             Ezagent.ActionSet.IdentityAdmin.handle_revoke_cap(%{cap: cap}, ctx)

    assert CapQuarantine.list_open(holder) == []
  end

  test "a stale quarantine request cannot reopen an identity already replaced by a signed cap" do
    holder = unique_holder("stale-request")
    expected = raw_cap(holder)
    replacement = Ezagent.Test.CapHelper.issue!(holder, expected)

    request = %Ezagent.Cap.HealRequest{
      expected: expected,
      class: :unknown,
      action: {:quarantine, :no_resolver}
    }

    ctx = %{
      caller: :vm_internal,
      self_uri: holder,
      read: fn :caps, _default -> MapSet.new([replacement]) end
    }

    assert {:ok, %{status: :stale}, []} =
             Ezagent.ActionSet.IdentityAdmin.handle_heal_cap(%{request: request}, ctx)

    assert CapQuarantine.list_open(holder) == []
  end

  test "closing stale artifact A cannot close a different-issuer artifact B row" do
    holder = unique_holder("aba-close")
    artifact_a = raw_cap(holder)

    artifact_b = %{
      artifact_a
      | granted_by: Ezagent.URI.user("team-alpha", "different-issuer"),
        granted_at: DateTime.add(artifact_a.granted_at, 1, :second)
    }

    assert :ok = CapQuarantine.record(holder, artifact_a, :unknown, :first)
    assert :ok = CapQuarantine.close(holder, artifact_a)
    assert :ok = CapQuarantine.record(holder, artifact_b, :unknown, :reopened)

    assert :ok = CapQuarantine.close(holder, artifact_a)
    assert [%{status: :open, granted_by: granted_by}] = CapQuarantine.list_open(holder)
    assert granted_by == URI.to_string(artifact_b.granted_by)
  end

  test "a normal signed grant closes the exact open quarantine work item" do
    holder = unique_holder("signed-grant")
    expected = raw_cap(holder)
    replacement = Ezagent.Test.CapHelper.issue!(holder, expected)
    assert :ok = CapQuarantine.record(holder, expected, :unknown, :no_resolver)

    ctx = %{
      caller: Ezagent.Entity.User.admin_uri(),
      self_uri: holder,
      caps: MapSet.new(),
      read: fn :caps, _default -> MapSet.new([expected]) end
    }

    assert {:ok, %{caps: caps}, _effects} =
             Ezagent.ActionSet.IdentityAdmin.handle_grant_cap(%{cap: replacement}, ctx)

    assert Enum.any?(caps, &(&1 === replacement))
    assert CapQuarantine.list_open(holder) == []
  end

  defp raw_cap(holder \\ Ezagent.URI.user("team-alpha", "quarantine-default")) do
    %Ezagent.Capability{
      kind: :user,
      behavior: __MODULE__.Unknown,
      action: :read,
      instance: holder,
      workspace_uri: Ezagent.URI.workspace("team-alpha"),
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp unique_holder(prefix) do
    Ezagent.URI.user("team-alpha", "#{prefix}-#{System.unique_integer([:positive])}")
  end
end
