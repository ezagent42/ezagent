defmodule Ezagent.Behavior.IdentityGrantTest do
  @moduledoc """
  Phase 6 PR 6 — grant_cap / revoke_cap behavior actions.

  Phase 9 PR-3 (SPEC v3 §4): caps carry `workspace_uri`. Tests pass
  the field explicitly since `@enforce_keys` rejects struct
  construction without it.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.{Identity, IdentityAdmin}
  alias Ezagent.Capability

  @workspace_uri URI.new!("workspace://team-alpha")
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
    ctx = %{caps: Ezagent.SystemPrincipal.caps("system://bootstrap")}

    {:ok, new_slice, %{caps: caps}} =
      IdentityAdmin.invoke(:grant_cap, slice, %{cap: new_cap}, ctx)

    assert MapSet.size(new_slice.caps) == 1
    assert new_cap in caps
  end

  test "revoke_cap removes from slice" do
    cap = echo_cap()

    slice = %{caps: MapSet.new([cap])}

    {:ok, new_slice, %{caps: caps}} =
      IdentityAdmin.invoke(:revoke_cap, slice, %{cap: cap}, %{})

    assert MapSet.size(new_slice.caps) == 0
    assert caps == []
  end

  test "grant_cap is idempotent (MapSet semantics)" do
    cap = echo_cap()

    slice = %{caps: MapSet.new([cap])}

    # See sibling test — admin caps required for wildcard grants
    # under PR-OWN-2 §5.2.
    ctx = %{caps: Ezagent.SystemPrincipal.caps("system://bootstrap")}

    {:ok, new_slice, _} = IdentityAdmin.invoke(:grant_cap, slice, %{cap: cap}, ctx)
    assert MapSet.size(new_slice.caps) == 1
  end

  test "IdentityAdmin interface declares grant_cap + revoke_cap (PR-OWN-3 split)" do
    iface = IdentityAdmin.interface()
    assert Map.has_key?(iface, :grant_cap)
    assert Map.has_key?(iface, :revoke_cap)
    assert iface.grant_cap.modes == [:call]
  end

  describe "notify_cap_change — `Notifications.notify` shape (regression: E2E 2026-05-25)" do
    # Bug: `IdentityAdmin.invoke(:grant_cap, ...)` calls private
    # `notify_cap_change/4` which posted a notification with the
    # legacy `%{kind:, text:, cap_summary:}` shape — but
    # `Ezagent.Notifications.notify/2` now requires
    # `%{type: atom, body: map, source: module}` and raises
    # `ArgumentError` otherwise. Surfaced via
    # `mix ezagent.feishu.bind ou_xxx entity://user/team-alpha/<u>`:
    # the binding row was saved but BindingPolicy cap-grant crashed
    # the dispatch path for non-admin users.
    test "grant_cap with `:self_uri` user ctx does NOT raise ArgumentError" do
      # Subscribe so we (a) verify no crash AND (b) verify the
      # notification reaches the user inbox with the new contract shape.
      user_uri = URI.parse("entity://user/team-alpha/notify_shape_grant")
      :ok = Ezagent.Notifications.subscribe(user_uri, %{caps: :system})

      ctx = %{
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        self_uri: user_uri
      }

      slice = %{caps: MapSet.new()}
      cap = echo_cap()

      assert {:ok, _new_slice, _result} =
               IdentityAdmin.invoke(:grant_cap, slice, %{cap: cap}, ctx)

      assert_receive {:notification, ^user_uri,
                      %{
                        type: :cap_granted,
                        body: %{text: text, cap_summary: cap_summary},
                        source: Ezagent.Behavior.IdentityAdmin
                      }},
                     1_000

      assert is_binary(text)
      assert is_binary(cap_summary)
    end

    test "revoke_cap with `:self_uri` user ctx does NOT raise ArgumentError" do
      user_uri = URI.parse("entity://user/team-alpha/notify_shape_revoke")
      :ok = Ezagent.Notifications.subscribe(user_uri, %{caps: :system})

      ctx = %{self_uri: user_uri}
      cap = echo_cap()
      slice = %{caps: MapSet.new([cap])}

      assert {:ok, _new_slice, _result} =
               IdentityAdmin.invoke(:revoke_cap, slice, %{cap: cap}, ctx)

      assert_receive {:notification, ^user_uri,
                      %{
                        type: :cap_revoked,
                        body: %{text: _, cap_summary: _},
                        source: Ezagent.Behavior.IdentityAdmin
                      }},
                     1_000
    end
  end

  describe "§5.2 admin predicate (codex PR-OWN-2 round-2 HIGH-1 regression)" do
    test "instance-scoped wildcard cap does NOT count as bootstrap admin" do
      # Codex round-2 HIGH-1: round-1's holds_admin_caps?/1 omitted
      # `instance: :any` from the match. A delegated cap with
      # `kind: :any, behavior: :any, instance: <target>, workspace: :any`
      # would have satisfied it — privilege escalation for that target.
      # Round-2 requires ALL FOUR :any wildcards.
      target_uri = URI.parse("entity://user/acme/victim-x")

      delegated_wildcard = %Capability{
        kind: :any,
        behavior: :any,
        # Narrowed to a specific instance — NOT bootstrap admin shape.
        instance: target_uri,
        workspace_uri: :any,
        granted_by: @granter,
        granted_at: DateTime.utc_now()
      }

      slice = %{caps: MapSet.new()}
      cap_to_grant = echo_cap()

      # Caller holds the delegated wildcard, attempts to grant
      # another wildcard cap. Round-1 buggy predicate would have
      # let this through. Round-2 must reject.
      ctx = %{caps: MapSet.new([delegated_wildcard])}

      assert {:error, :grant_wildcard_requires_admin} =
               IdentityAdmin.invoke(:grant_cap, slice, %{cap: cap_to_grant}, ctx)
    end

    test "only the all-four-wildcards bootstrap-admin shape qualifies" do
      # Sanity: verify the EXACT shape passes (positive test pairing
      # with the negative above).
      slice = %{caps: MapSet.new()}
      cap_to_grant = echo_cap()
      ctx = %{caps: Ezagent.SystemPrincipal.caps("system://bootstrap")}

      assert {:ok, _new_slice, _result} =
               IdentityAdmin.invoke(:grant_cap, slice, %{cap: cap_to_grant}, ctx)
    end
  end
end
