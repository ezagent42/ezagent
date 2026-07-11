defmodule Ezagent.ActionSet.IdentityGrantTest do
  @moduledoc """
  Phase 6 PR 6 — grant_cap / revoke_cap behavior actions.

  Phase 9 PR-3 (SPEC v3 §4): caps carry `workspace_uri`. Tests pass
  the field explicitly since `@enforce_keys` rejects struct
  construction without it.

  P2-b migration (2026-05-28): rewritten to exercise the new-contract
  `handle_grant_cap/2` / `handle_revoke_cap/2` handlers.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.IdentityAdmin
  alias Ezagent.Capability

  @workspace_uri URI.new!("workspace://team-alpha")
  @granter Ezagent.URI.new!("entity://system/user/admin")

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

  defp ctx_with(caller_caps, slice_caps) do
    %{
      caller: @granter,
      caps: caller_caps,
      self_uri: Ezagent.URI.new!("entity://team-alpha/user/target"),
      reply: :sync,
      read: fn key, default ->
        case key do
          :caps -> slice_caps
          _ -> default
        end
      end
    }
  end

  test "grant_cap adds to slice + returns updated list via :set effect" do
    new_cap = echo_cap()

    # PR-OWN-2 §5.2: wildcard caps require bootstrap-admin caller.
    ctx = ctx_with(MapSet.new([Ezagent.Capability.admin_genesis_cap()]), MapSet.new())

    {:ok, %{caps: caps}, effects} =
      IdentityAdmin.handle_grant_cap(%{cap: new_cap}, ctx)

    # The :set effect carries the new MapSet.
    assert {:set, :caps, new_set} = Enum.find(effects, &match?({:set, :caps, _}, &1))
    assert MapSet.size(new_set) == 1
    assert new_cap in caps
  end

  test "revoke_cap removes from slice via :set effect" do
    cap = echo_cap()
    ctx = ctx_with(MapSet.new(), MapSet.new([cap]))

    {:ok, %{caps: caps}, effects} =
      IdentityAdmin.handle_revoke_cap(%{cap: cap}, ctx)

    assert {:set, :caps, new_set} = Enum.find(effects, &match?({:set, :caps, _}, &1))
    assert MapSet.size(new_set) == 0
    assert caps == []
  end

  test "grant_cap is idempotent (MapSet semantics + identity-tuple dedup)" do
    cap = echo_cap()
    ctx = ctx_with(MapSet.new([Ezagent.Capability.admin_genesis_cap()]), MapSet.new([cap]))

    {:ok, _result, effects} = IdentityAdmin.handle_grant_cap(%{cap: cap}, ctx)
    assert {:set, :caps, new_set} = Enum.find(effects, &match?({:set, :caps, _}, &1))
    assert MapSet.size(new_set) == 1
  end

  test "IdentityAdmin __actions__/0 declares grant_cap + revoke_cap (PR-OWN-3 split)" do
    action_specs = IdentityAdmin.__actions__()
    assert Map.has_key?(action_specs, :grant_cap)
    assert Map.has_key?(action_specs, :revoke_cap)
    assert action_specs.grant_cap.modes == [:call]
  end

  describe "notify_cap_change — `Notifications.notify` shape (regression: E2E 2026-05-25)" do
    test "grant_cap with `:self_uri` user ctx does NOT raise ArgumentError" do
      user_uri = Ezagent.URI.new!("entity://team-alpha/user/notify_shape_grant")
      :ok = Ezagent.Notifications.subscribe(user_uri)

      ctx = %{
        caller: @granter,
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        self_uri: user_uri,
        read: fn key, default ->
          case key do
            :caps -> MapSet.new()
            _ -> default
          end
        end
      }

      cap = echo_cap()

      assert {:ok, _result, _effects} = IdentityAdmin.handle_grant_cap(%{cap: cap}, ctx)

      assert_receive {:notification, ^user_uri,
                      %{
                        type: :cap_granted,
                        body: %{text: text, cap_summary: cap_summary},
                        source: Ezagent.ActionSet.IdentityAdmin
                      }},
                     1_000

      assert is_binary(text)
      assert is_binary(cap_summary)
    end

    test "revoke_cap with `:self_uri` user ctx does NOT raise ArgumentError" do
      user_uri = Ezagent.URI.new!("entity://team-alpha/user/notify_shape_revoke")
      :ok = Ezagent.Notifications.subscribe(user_uri)

      cap = echo_cap()

      ctx = %{
        caller: @granter,
        caps: MapSet.new(),
        self_uri: user_uri,
        read: fn key, default ->
          case key do
            :caps -> MapSet.new([cap])
            _ -> default
          end
        end
      }

      assert {:ok, _result, _effects} = IdentityAdmin.handle_revoke_cap(%{cap: cap}, ctx)

      assert_receive {:notification, ^user_uri,
                      %{
                        type: :cap_revoked,
                        body: %{text: _, cap_summary: _},
                        source: Ezagent.ActionSet.IdentityAdmin
                      }},
                     1_000
    end
  end

  describe "§5.2 admin predicate (codex PR-OWN-2 round-2 HIGH-1 regression)" do
    test "dispatch handler is store-only and does not re-authorize an issued artifact" do
      cap = echo_cap()
      ctx = ctx_with(MapSet.new(), MapSet.new())

      assert {:error, :wildcard_action_grant_requires_admin_authority} =
               Ezagent.CapabilityRegistry.authorize_grant(ctx.caps, cap, %{caller: ctx.caller})

      assert {:ok, _result, effects} = IdentityAdmin.handle_grant_cap(%{cap: cap}, ctx)
      assert {:set, :caps, _} = Enum.find(effects, &match?({:set, :caps, _}, &1))
    end

    test "dispatch handler verifies provenance without re-authorizing the grantor" do
      forged = %{echo_cap() | granted_by: Ezagent.URI.new!("system://forged")}
      ctx = ctx_with(MapSet.new(), MapSet.new())

      assert {:error, :invalid_cap_artifact} =
               IdentityAdmin.handle_grant_cap(%{cap: forged}, ctx)
    end

    test "instance-scoped wildcard cap does NOT count as bootstrap admin" do
      target_uri = Ezagent.URI.new!("entity://acme/user/victim-x")

      delegated_wildcard = %Capability{
        kind: :any,
        behavior: :any,
        instance: target_uri,
        workspace_uri: :any,
        granted_by: @granter,
        granted_at: DateTime.utc_now()
      }

      cap_to_grant = echo_cap()
      ctx = ctx_with(MapSet.new([delegated_wildcard]), MapSet.new())

      # SPEC 2026-05-27 capability-action-axis §3.6.1(b): the
      # action-wildcard runtime check fires BEFORE the per-shape
      # workspace-admin check.
      assert {:error, :wildcard_action_grant_requires_admin_authority} =
               Ezagent.CapabilityRegistry.authorize_grant(ctx.caps, cap_to_grant, %{
                 caller: ctx.caller
               })
    end

    test "only the all-four-wildcards bootstrap-admin shape qualifies" do
      cap_to_grant = echo_cap()
      ctx = ctx_with(MapSet.new([Ezagent.Capability.admin_genesis_cap()]), MapSet.new())

      assert :ok =
               Ezagent.CapabilityRegistry.authorize_grant(ctx.caps, cap_to_grant, %{
                 caller: ctx.caller
               })

      assert {:ok, _result, _effects} =
               IdentityAdmin.handle_grant_cap(%{cap: cap_to_grant}, ctx)
    end
  end
end
