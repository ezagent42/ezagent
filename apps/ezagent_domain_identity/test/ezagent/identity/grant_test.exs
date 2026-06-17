defmodule Ezagent.Identity.GrantTest do
  @moduledoc """
  Unit tests for the unified grant chokepoint `Ezagent.Identity.Grant`
  (SPEC 2026-06-17 §5). The derivation tests inspect the `%Cmd{}` built
  by the effect wrappers (which surface `prepare/4`'s output WITHOUT a
  live Kind dispatch); the authorization-semantics tests dispatch for
  real against spawned Entity Kinds.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Identity.Grant

  @template_materialize Ezagent.SystemPrincipal.uri("template-materialize")
  @admin_uri Ezagent.Entity.User.admin_uri()

  defp ws, do: Ezagent.URI.new!("workspace://team-alpha")

  defp target_user do
    Ezagent.URI.new!("entity://team-alpha/user/grantee-#{System.unique_integer([:positive])}")
  end

  # A concrete, scope-bounded cap (passes both the wildcard gate and the
  # rule branch's `rule_cap_bounded?`).
  defp concrete_cap do
    %Capability{
      kind: :session_template,
      behavior: Ezagent.Behavior.Template,
      action: :any,
      instance: {:within_workspace, ws()},
      workspace_uri: ws(),
      # a deliberately WRONG (system-principal) granted_by, to prove the
      # chokepoint OVERWRITES it.
      granted_by: @template_materialize,
      granted_at: ~U[2020-01-01 00:00:00Z]
    }
  end

  describe "prepare derivation (via grant_cap_effect — no dispatch)" do
    test "{:system, principal, entity} loads the principal's caps + entity granted_by" do
      configurer = Ezagent.URI.new!("entity://team-alpha/user/owner")

      {:dispatch, cmd} =
        Grant.grant_cap_effect(target_user(), concrete_cap(), {:system, @template_materialize, configurer})

      # ctx.caps == the principal's catalog caps (the authorizer)
      expected = Ezagent.SystemPrincipal.caps(@template_materialize)
      assert cmd.ctx.caps == expected
      # ctx.caller == the ENTITY granted_by (NOT the principal) — the
      # handler self-check reads ctx.caller; caps carries the principal's
      # authority. See derive/1's deviation note.
      assert cmd.ctx.caller == configurer
      # granted_by OVERWRITTEN to the entity configurer (HIGH-1 regression)
      assert cmd.args.cap.granted_by == configurer
      assert %URI{scheme: "entity"} = cmd.args.cap.granted_by
      # action baked onto the target
      assert cmd.action == :grant_cap
      refute Map.has_key?(cmd.ctx, :authorization_rule)
    end

    test "a %Capability{} arriving with a system:// granted_by is OVERWRITTEN to the entity" do
      configurer = Ezagent.URI.new!("entity://team-alpha/user/owner")
      cap = concrete_cap()
      assert cap.granted_by == @template_materialize

      {:dispatch, cmd} =
        Grant.grant_cap_effect(target_user(), cap, {:system, @template_materialize, configurer})

      assert cmd.args.cap.granted_by == configurer
    end

    test "{:rule, name, configurer} sets the rule flag + [] caps + configurer granted_by" do
      configurer = Ezagent.URI.new!("entity://team-alpha/user/operator")

      {:dispatch, cmd} =
        Grant.grant_cap_effect(target_user(), concrete_cap(), {:rule, :feishu_binding, configurer})

      assert cmd.ctx.authorization_rule == :feishu_binding
      assert cmd.ctx.caps == MapSet.new()
      assert cmd.ctx.caller == configurer
      assert cmd.args.cap.granted_by == configurer
    end

    test "revoke_cap_returning_effect builds a :revoke_cap dispatch_returning with bind_as" do
      configurer = Ezagent.URI.new!("entity://team-alpha/user/owner")

      {:dispatch_returning, cmd, opts} =
        Grant.revoke_cap_returning_effect(
          target_user(),
          concrete_cap(),
          {:system, @template_materialize, configurer},
          :my_bind
        )

      assert cmd.action == :revoke_cap
      assert opts[:bind_as] == :my_bind
      assert cmd.args.cap.granted_by == configurer
    end
  end

  describe "the runtime #154 entity guard (prepare/4 refuses a non-entity granted_by)" do
    test "{:system, p, system://…} is REFUSED — the granted_by arg must be an entity" do
      non_entity = Ezagent.SystemPrincipal.uri("template-materialize")

      assert {:error, {:granter_not_entity, ^non_entity}} =
               Grant.grant_cap(target_user(), concrete_cap(), {:system, @template_materialize, non_entity})
    end

    test "effect wrappers RAISE on a non-entity derived granted_by (fail-fast)" do
      non_entity = Ezagent.SystemPrincipal.uri("template-materialize")

      assert_raise ArgumentError, ~r/granter_not_entity/, fn ->
        Grant.grant_cap_effect(target_user(), concrete_cap(), {:system, @template_materialize, non_entity})
      end
    end

    test "the documented admin fallback (entity://system/user/admin) passes the guard" do
      {:dispatch, cmd} =
        Grant.grant_cap_effect(target_user(), concrete_cap(), {:system, @template_materialize, @admin_uri})

      assert cmd.args.cap.granted_by == @admin_uri
      assert %URI{scheme: "entity"} = cmd.args.cap.granted_by
    end
  end

  # rule_cap_bounded?/1 is tested as a PURE PREDICATE on `IdentityAdmin`,
  # NOT through dispatch. The rule branch is dormant in PR-1: a `{:rule, …}`
  # grant carries `ctx.caps = []`, so dispatch step 5.5 denies with
  # `:unauthorized` before the handler runs. PR-2/PR-3 (the first
  # `{:rule, …}` callers) make the path reachable (teach step 5.5 to
  # honor `ctx[:authorization_rule]`, or route via `trusted_slice_update/3`).
  describe "IdentityAdmin.rule_cap_bounded?/1 — the §3.3 structural bound (pure predicate)" do
    alias Ezagent.Behavior.IdentityAdmin

    test "a scope-bounded concrete cap is bounded (accepted)" do
      assert IdentityAdmin.rule_cap_bounded?(concrete_cap())
    end

    test "a kind: :any cap is NOT bounded (rejected)" do
      refute IdentityAdmin.rule_cap_bounded?(%{concrete_cap() | kind: :any})
    end

    test "a behavior: :any cap is NOT bounded (rejected)" do
      refute IdentityAdmin.rule_cap_bounded?(%{concrete_cap() | behavior: :any})
    end

    test "action: :any + a CONCRETE (non-scope-bounded) %URI{} instance is NOT bounded" do
      # Mirrors check_action_wildcard_grant_authorized exactly: action :any
      # requires a scope-bounded instance, never a plain concrete %URI{}.
      refute IdentityAdmin.rule_cap_bounded?(%{concrete_cap() | action: :any, instance: ws()})
    end

    test "a concrete action + concrete %URI{} instance IS bounded (accepted)" do
      cap = %{concrete_cap() | action: :read, instance: ws()}
      assert IdentityAdmin.rule_cap_bounded?(cap)
    end
  end

  describe "{:held_by, actor} authorization (#811 admin / manager-delegated)" do
    test "{:held_by, admin} authorizes an admin grant against a live grantee" do
      {:ok, _} = Ezagent.SpawnRegistry.spawn(@admin_uri)
      Ezagent.ReadyGate.await(@admin_uri, 2_000)

      grantee = target_user()
      {:ok, _} = Ezagent.SpawnRegistry.spawn(grantee)
      Ezagent.ReadyGate.await(grantee, 2_000)

      # The admin holds the all-:any cap; {:held_by, admin} loads it as the
      # authorizer → the grant is authorized; granted_by == admin (entity).
      assert :ok = Grant.grant_cap(grantee, concrete_cap(), {:held_by, @admin_uri})

      caps = Ezagent.Identity.list_caps_for(grantee)

      assert Enum.any?(caps, fn c ->
               c.behavior == Ezagent.Behavior.Template and c.granted_by == @admin_uri
             end)
    end
  end
end
