defmodule Ezagent.Identity.GrantTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Identity}
  alias Ezagent.Identity.Grant

  setup do
    suffix = System.unique_integer([:positive])
    workspace_name = "grant-contract-#{suffix}"
    workspace = Ezagent.URI.workspace(workspace_name)
    grantee = Ezagent.URI.user(workspace_name, "grantee-#{suffix}")

    {:ok, _pid} = Ezagent.Workspace.create(workspace_name, %{})
    {:ok, _user} = Ezagent.Users.create(grantee, nil, [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(grantee)

    cap =
      Capability.cap(
        :workspace,
        Ezagent.ActionSet.Workspace,
        :list_members,
        workspace,
        workspace
      )

    %{workspace: workspace, grantee: grantee, cap: cap}
  end

  test "admin anchor causes the concrete target Kind to sign before storage", ctx do
    assert :ok = Grant.grant_cap(ctx.grantee, ctx.cap, {:admin, admin_uri()})

    assert %Capability{} = stored = find_cap(ctx.grantee, ctx.cap)
    assert stored.granted_by == admin_uri()
    assert stored.grantee_uri == ctx.grantee
    assert is_binary(stored.key_id) and stored.key_id != ""
    assert is_binary(stored.signature) and byte_size(stored.signature) > 0
  end

  test "grant effect carries only the VM-internal signed-artifact hand-off", ctx do
    assert {:dispatch, %Ezagent.Cmd{} = cmd} =
             Grant.grant_cap_effect(ctx.grantee, ctx.cap, {:admin, admin_uri()})

    assert cmd.action == :store_cap
    assert cmd.origin == :trusted_internal
    assert cmd.ctx.caller == :vm_internal
    assert cmd.ctx.cap_delivery_producer == :identity_grant
    assert %Capability{} = artifact = cmd.args.cap
    assert artifact.grantee_uri == ctx.grantee
    assert is_binary(artifact.signature)
  end

  test "revoke removes the matching signed artifact without minting again", ctx do
    assert :ok = Grant.grant_cap(ctx.grantee, ctx.cap, {:admin, admin_uri()})
    assert %Capability{} = stored = find_cap(ctx.grantee, ctx.cap)

    assert :ok = Grant.revoke_cap(ctx.grantee, stored, {:admin, admin_uri()})
    refute find_cap(ctx.grantee, ctx.cap)
  end

  test "revoke effect uses the distinct storage action and delivery marker", ctx do
    assert {:dispatch_returning, %Ezagent.Cmd{} = cmd, bind_as: :removed} =
             Grant.revoke_cap_returning_effect(
               ctx.grantee,
               ctx.cap,
               {:admin, admin_uri()},
               :removed
             )

    assert cmd.action == :remove_cap
    assert cmd.origin == :trusted_internal
    assert cmd.ctx.caller == :vm_internal
    assert cmd.ctx.cap_delivery_producer == :identity_revoke
  end

  test "targetless grants fail closed before any artifact is delivered", ctx do
    targetless = %{ctx.cap | instance: :any}

    assert {:error, :concrete_target_required} =
             Grant.grant_cap(ctx.grantee, targetless, {:admin, admin_uri()})

    refute find_cap(ctx.grantee, targetless)
  end

  test "removed genesis and rule authorization forms have no compatibility clause", ctx do
    assert_raise FunctionClauseError, fn ->
      Grant.grant_cap(ctx.grantee, ctx.cap, {:genesis, admin_uri()})
    end

    assert_raise FunctionClauseError, fn ->
      Grant.grant_cap(ctx.grantee, ctx.cap, {:rule, :legacy, admin_uri()})
    end
  end

  defp find_cap(grantee, shape) do
    grantee
    |> Identity.list_caps_for()
    |> Enum.find(&(Capability.identity_key(&1) == Capability.identity_key(shape)))
  end

  defp admin_uri, do: Ezagent.Entity.User.admin_uri()
end
