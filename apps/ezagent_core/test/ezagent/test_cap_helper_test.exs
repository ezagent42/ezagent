defmodule Ezagent.Test.CapHelperTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.Authority
  alias Ezagent.Capability

  import Ezagent.Test.CapHelper

  test "signed_ctx! projects the unsigned admin wildcard onto the concrete target" do
    target =
      Ezagent.URI.new!(
        "session://team-alpha/default/cap-helper-#{System.unique_integer([:positive])}"
      )

    admin = Ezagent.URI.user(:system, :admin)

    ctx = %{
      caller: admin,
      caps: MapSet.new([Capability.admin_genesis_cap()])
    }

    %{authenticated_principal: holder, caps: caps} = signed_ctx!(target, ctx, :session)

    assert holder == admin
    assert [projected] = MapSet.to_list(caps)
    assert {:ok, ^target} = Authority.target_uri(projected)
    assert projected.kind == :any
    assert projected.behavior == :any
    assert projected.action == :any
    assert is_binary(projected.key_id)
    assert is_binary(projected.signature)
  end

  test "self_license_cap! issues a current target-bound license" do
    holder =
      Ezagent.URI.new!(
        "entity://team-alpha/user/cap-helper-holder-#{System.unique_integer([:positive])}"
      )

    license = self_license_cap!(holder)

    assert Capability.action_of(license) == :self_license
    assert {:ok, ^holder} = Authority.target_uri(license)
    assert Authority.verify_against_current(license, holder, holder)
  end
end
