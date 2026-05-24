defmodule Ezagent.Behavior.IdentityGrantTest do
  @moduledoc """
  Phase 6 PR 6 — grant_cap / revoke_cap behavior actions.

  Phase 9 PR-3 (SPEC v3 §4): caps carry `workspace_uri`. Tests pass
  the field explicitly since `@enforce_keys` rejects struct
  construction without it.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.Identity
  alias Ezagent.Capability

  @workspace_uri URI.new!("workspace://default")
  @granter URI.parse("entity://user/system/admin")

  defp echo_cap do
    %Capability{
      kind: :echo,
      behavior: :any,
      instance: :any,
      workspace_uri: @workspace_uri,
      granted_by: @granter,
      granted_at: DateTime.utc_now()
    }
  end

  test "grant_cap adds to slice + returns updated list" do
    slice = %{caps: MapSet.new()}

    new_cap = echo_cap()

    # PR-OWN-2 §5.2: wildcard caps (`behavior: :any`) require the
    # caller to hold the bootstrap admin marker. Provide admin caps
    # in ctx — test direct invoke bypasses dispatch's CapBAC gate
    # which would have set this in production.
    ctx = %{caps: Ezagent.Entity.User.admin_caps()}

    {:ok, new_slice, %{caps: caps}} =
      Identity.invoke(:grant_cap, slice, %{cap: new_cap}, ctx)

    assert MapSet.size(new_slice.caps) == 1
    assert new_cap in caps
  end

  test "revoke_cap removes from slice" do
    cap = echo_cap()

    slice = %{caps: MapSet.new([cap])}

    {:ok, new_slice, %{caps: caps}} =
      Identity.invoke(:revoke_cap, slice, %{cap: cap}, %{})

    assert MapSet.size(new_slice.caps) == 0
    assert caps == []
  end

  test "grant_cap is idempotent (MapSet semantics)" do
    cap = echo_cap()

    slice = %{caps: MapSet.new([cap])}

    # See sibling test — admin caps required for wildcard grants
    # under PR-OWN-2 §5.2.
    ctx = %{caps: Ezagent.Entity.User.admin_caps()}

    {:ok, new_slice, _} = Identity.invoke(:grant_cap, slice, %{cap: cap}, ctx)
    assert MapSet.size(new_slice.caps) == 1
  end

  test "interface declares grant_cap + revoke_cap" do
    iface = Identity.interface()
    assert Map.has_key?(iface, :grant_cap)
    assert Map.has_key?(iface, :revoke_cap)
    assert iface.grant_cap.modes == [:call]
  end
end
