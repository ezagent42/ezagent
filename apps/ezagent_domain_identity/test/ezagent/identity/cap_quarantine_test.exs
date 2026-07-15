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

  defp raw_cap do
    %Ezagent.Capability{
      kind: :user,
      behavior: __MODULE__.Unknown,
      action: :read,
      instance: :any,
      workspace_uri: Ezagent.URI.workspace("team-alpha"),
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end
end
