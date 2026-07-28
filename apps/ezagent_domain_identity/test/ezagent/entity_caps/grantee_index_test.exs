defmodule Ezagent.EntityCaps.GranteeIndexTest do
  @moduledoc """
  URI-share unification (A2-2) — the reverse cap index `grantees_of`.

  A projection of "who currently holds a cap toward target T", maintained at the
  single cap-store funnel (`persist_entity_caps`, reached by absorb/grant/
  persist/store/remove) and filtered at read by the target's CURRENT authority
  generation — so a `revoke_all_to` generation bump makes stale rows disappear
  WITHOUT a delete (mirrors `verify_against_current`, no new revocation path).

  This is the seam `:session`'s `:members` roster becomes a projection of (A4-2),
  and the reverse half of A2-1's forward `caps_toward`.
  """
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.Capability
  alias Ezagent.EntityCaps.GranteeIndex
  alias Ezagent.ActionSet.IdentityAdmin

  @workspace URI.new!("workspace://team-alpha")
  @issuer URI.new!("entity://team-alpha/user/issuer")
  # H2: grantees_of is caller-authorized. The canonical system admin manages any
  # target, so it is the authorized caller for these enumeration assertions.
  @admin Ezagent.URI.user(:system, :admin)

  # A concrete shared target (a session instance, exactly like the absorb-cap
  # fixture) plus a distinct target to prove per-target isolation.
  # 3-segment canonical session URI. The 2nd segment is a static literal followed
  # by `/` so the "no 2-segment session:// literal" grep gate (which would see an
  # interpolation right after the 2nd segment as a terminated 2-segment URI) skips it.
  defp target(suffix),
    do:
      Ezagent.URI.new!(
        "session://team-alpha/boards/#{suffix}-#{System.unique_integer([:positive])}"
      )

  defp grantee(suffix),
    do:
      Ezagent.URI.new!(
        "entity://team-alpha/user/grantee-#{suffix}-#{System.unique_integer([:positive])}"
      )

  defp cap_toward(target_uri, behavior, action) do
    %Capability{
      kind: :session,
      behavior: behavior,
      action: action,
      instance: target_uri,
      workspace_uri: @workspace,
      granted_by: @issuer,
      granted_at: DateTime.utc_now()
    }
  end

  # Sign `cap` under the target's CURRENT authority generation (stamps key_id) and
  # store it into `receiver`'s slice through the real handler — which runs
  # `persist_entity_caps` synchronously, exercising the reverse-index write hook.
  defp absorb!(target_uri, receiver, behavior, action) do
    {:ok, authority} = Ezagent.Cap.Authority.open(target_uri, :session)

    signed =
      authority_signed_cap_as!(
        authority,
        @issuer,
        receiver,
        cap_toward(target_uri, behavior, action)
      )

    assert {:ok, _result, _effects} =
             IdentityAdmin.handle_absorb_cap(%{artifact: signed}, ctx(receiver))

    signed
  end

  defp ctx(self_uri, caps \\ MapSet.new()) do
    %{caller: :vm_internal, self_uri: self_uri, read: fn :caps, _default -> caps end}
  end

  test "absorbing a cap toward a target lists the grantee in grantees_of/1 + behavior filter" do
    t = target("list")
    g = grantee("clicker")
    absorb!(t, g, :example, :send)

    assert GranteeIndex.grantees_of(t, @admin) == [g]
    assert GranteeIndex.grantees_of(t, @admin, :example) == [g]
    # A behavior no cap points at → empty (behavior is a real match axis, not :any).
    assert GranteeIndex.grantees_of(t, @admin, :other_behavior) == []
  end

  test "H2: a caller that does NOT manage the target enumerates nothing (fail-closed)" do
    t = target("h2")
    g = grantee("member")
    absorb!(t, g, :example, :send)

    # The admin (a manager) sees the grantee...
    assert GranteeIndex.grantees_of(t, @admin) == [g]

    # ...but a stranger who merely knows the target URI enumerates nothing —
    # knowing a URI is not authority to see who it was shared with.
    stranger = grantee("stranger")
    assert GranteeIndex.grantees_of(t, stranger) == []
  end

  test "grantees_of is isolated per target — a cap toward T1 never leaks into T2" do
    t1 = target("t1")
    t2 = target("t2")
    g = grantee("shared")

    absorb!(t1, g, :example, :send)
    # Open t2's authority so it is a live, valid target with zero grants.
    {:ok, _} = Ezagent.Cap.Authority.open(t2, :session)

    assert GranteeIndex.grantees_of(t1, @admin) == [g]
    assert GranteeIndex.grantees_of(t2, @admin) == []
  end

  test "a generation bump (revoke_all_to) auto-invalidates stale rows WITHOUT deleting them" do
    t = target("revoked")
    g = grantee("holder")
    absorb!(t, g, :example, :send)

    assert GranteeIndex.grantees_of(t, @admin) == [g]

    # Revocation-by-generation: bump the target's authority. The stored row keeps
    # its old key_id, which no longer matches the active generation → filtered out.
    assert {:ok, _authority} = Ezagent.Cap.Authority.regenesis(t, :session)

    assert GranteeIndex.grantees_of(t, @admin) == []
  end

  test "re-indexing a grantee reflects a removed cap (the store funnel drops it)" do
    t = target("removed")
    g = grantee("churn")
    absorb!(t, g, :example, :send)
    assert GranteeIndex.grantees_of(t, @admin) == [g]

    # A subsequent store of an empty set for the same grantee (mirrors the
    # remove_cap / EntityCaps.revoke funnel handing `persist_entity_caps` the new,
    # smaller set) drops the reverse row.
    :ok = GranteeIndex.reindex(g, MapSet.new())
    assert GranteeIndex.grantees_of(t, @admin) == []
  end

  test "distinct grantees toward one target are all listed, de-duplicated" do
    t = target("many")
    g1 = grantee("a")
    g2 = grantee("b")

    absorb!(t, g1, :example, :send)
    # g2 holds TWO caps toward t (two actions) — must appear exactly once.
    {:ok, authority} = Ezagent.Cap.Authority.open(t, :session)
    c1 = authority_signed_cap_as!(authority, @issuer, g2, cap_toward(t, :example, :send))
    c2 = authority_signed_cap_as!(authority, @issuer, g2, cap_toward(t, :example, :read))
    assert {:ok, _r, _e} = IdentityAdmin.handle_absorb_cap(%{artifact: c1}, ctx(g2))

    assert {:ok, _r, _e} =
             IdentityAdmin.handle_absorb_cap(%{artifact: c2}, ctx(g2, MapSet.new([c1])))

    assert Enum.sort(GranteeIndex.grantees_of(t, @admin)) == Enum.sort([g1, g2])
  end
end
