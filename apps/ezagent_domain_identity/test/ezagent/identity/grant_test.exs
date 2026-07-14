defmodule Ezagent.Identity.GrantTest do
  @moduledoc """
  Unit tests for the unified grant chokepoint `Ezagent.Identity.Grant`
  (SPEC 2026-06-17 §5). The derivation tests inspect the `%Cmd{}` built
  by the effect wrappers (which surface `prepare/4`'s output WITHOUT a
  live Kind dispatch); the authorization-semantics tests dispatch for
  real against spawned Entity Kinds.
  """
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.Cap.Delivery
  alias Ezagent.Capability
  alias Ezagent.Identity.Grant
  alias EzagentCore.Repo

  # A non-entity (system-scheme) URI used to prove the chokepoint OVERWRITES a
  # pre-existing non-entity `granted_by` and REFUSES a non-entity derived
  # granter. (#154 genesis collapse 2026-06-20 — the former
  # `@template_materialize` principal was eliminated; a raw `system://` URI
  # serves the same "deliberately wrong granter" role without a Catalog lookup.)
  @nonentity_granter Ezagent.URI.new!("system://bootstrap")
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
      behavior: Ezagent.ActionSet.Template,
      action: :any,
      instance: {:within_workspace, ws()},
      workspace_uri: ws(),
      # a deliberately WRONG (non-entity, system-scheme) granted_by, to prove
      # the chokepoint OVERWRITES it.
      granted_by: @nonentity_granter,
      granted_at: ~U[2020-01-01 00:00:00Z]
    }
  end

  describe "prepare derivation (via grant_cap_effect — no dispatch)" do
    test "{:genesis, entity} loads the genesis caps + entity granted_by" do
      configurer = Ezagent.URI.new!("entity://team-alpha/user/owner")

      {:dispatch, cmd} =
        Grant.grant_cap_effect(target_user(), concrete_cap(), {:genesis, configurer})

      # ctx.caps == the canonical admin-granted genesis wildcard (the authorizer)
      expected = MapSet.new([Ezagent.Capability.admin_genesis_cap()])
      assert cmd.ctx.caps == expected
      # ctx.caller == the ENTITY granted_by — the handler self-check reads
      # ctx.caller; caps carries the genesis authority. See derive/1's note.
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
      assert cap.granted_by == @nonentity_granter

      {:dispatch, cmd} =
        Grant.grant_cap_effect(target_user(), cap, {:genesis, configurer})

      assert cmd.args.cap.granted_by == configurer
    end

    test "{:rule, name, configurer} sets the rule flag + [] caps + configurer granted_by" do
      configurer = Ezagent.URI.new!("entity://team-alpha/user/operator")

      {:dispatch, cmd} =
        Grant.grant_cap_effect(
          target_user(),
          concrete_cap(),
          {:rule, :feishu_binding, configurer}
        )

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
          {:genesis, configurer},
          :my_bind
        )

      assert cmd.action == :revoke_cap
      assert opts[:bind_as] == :my_bind
      assert cmd.args.cap.granted_by == configurer
    end
  end

  describe "the runtime #154 entity guard (prepare/4 refuses a non-entity granted_by)" do
    test "{:genesis, system://…} is REFUSED — the granted_by arg must be an entity" do
      non_entity = @nonentity_granter

      assert {:error, {:granter_not_entity, ^non_entity}} =
               Grant.grant_cap(target_user(), concrete_cap(), {:genesis, non_entity})
    end

    test "effect wrappers RAISE on a non-entity derived granted_by (fail-fast)" do
      assert_raise ArgumentError, ~r/granter_not_entity/, fn ->
        Grant.grant_cap_effect(target_user(), concrete_cap(), {:genesis, @nonentity_granter})
      end
    end

    test "the documented admin fallback (entity://system/user/admin) passes the guard" do
      {:dispatch, cmd} =
        Grant.grant_cap_effect(target_user(), concrete_cap(), {:genesis, @admin_uri})

      assert cmd.args.cap.granted_by == @admin_uri
      assert %URI{scheme: "entity"} = cmd.args.cap.granted_by
    end
  end

  describe "grant_cap_via_router/4 reply mode — regression guard (workspace.ex site #3)" do
    # The base `grant_creator_manage_cap` grant used `mode: :call` so its
    # caller gates create-success on the grant result. The chokepoint default
    # is `:async` (:cast), which would SILENTLY SWALLOW a grant failure. This
    # pins that `:sync` propagates the error and `:async` does not — the exact
    # contract site #3 relies on.
    test ":sync propagates a grant-authorization failure; :async swallows it (:cast)" do
      grantee = target_user()
      {:ok, _} = Ezagent.SpawnRegistry.spawn(grantee)
      Ezagent.ReadyGate.await(grantee, 2_000)

      # An actor with NO admin/grant authority.
      unauth = target_user()
      {:ok, _} = Ezagent.SpawnRegistry.spawn(unauth)
      Ezagent.ReadyGate.await(unauth, 2_000)

      # A full-wildcard cap: `check_action_wildcard_grant_authorized` rejects
      # it for a non-admin caller — a deterministic authz failure independent
      # of any data-owner branch. granted_by is overwritten to `unauth` (entity).
      wildcard = %Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: @admin_uri,
        granted_at: ~U[2020-01-01 00:00:00Z]
      }

      # :sync → :call → the authorization failure PROPAGATES.
      assert {:error, _} =
               Grant.grant_cap_via_router(grantee, wildcard, {:held_by, unauth}, :sync)

      # Issue-time authorization runs before either envelope is dispatched, so
      # async can no longer swallow an authorization failure.
      assert {:error, _} =
               Grant.grant_cap_via_router(grantee, wildcard, {:held_by, unauth}, :async)
    end
  end

  # rule_cap_bounded?/1 is tested as a PURE PREDICATE on `IdentityAdmin`,
  # NOT through dispatch. The rule branch is dormant in PR-1: a `{:rule, …}`
  # grant carries `ctx.caps = []`, so dispatch step 5.5 denies with
  # `:unauthorized` before the handler runs. PR-2/PR-3 (the first
  # `{:rule, …}` callers) make the path reachable (teach step 5.5 to
  # honor `ctx[:authorization_rule]`, or route via `trusted_slice_update/3`).
  describe "IdentityAdmin.rule_cap_bounded?/1 — the §3.3 structural bound (pure predicate)" do
    alias Ezagent.ActionSet.IdentityAdmin

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
               c.behavior == Ezagent.ActionSet.Template and c.granted_by == @admin_uri
             end)
    end
  end

  describe "C3 revoke authorization remains unchanged" do
    test "ordinary held-cap revoke still removes the matching capability" do
      grantee = target_user()
      {:ok, _} = Ezagent.SpawnRegistry.spawn(@admin_uri)
      {:ok, _} = Ezagent.SpawnRegistry.spawn(grantee)
      Ezagent.ReadyGate.await(@admin_uri, 2_000)
      Ezagent.ReadyGate.await(grantee, 2_000)

      assert :ok = Grant.grant_cap(grantee, concrete_cap(), {:held_by, @admin_uri})
      assert cap_present?(grantee)

      assert :ok = Grant.revoke_cap(grantee, concrete_cap(), {:held_by, @admin_uri})
      refute cap_present?(grantee)

      delivery =
        Repo.one!(
          from(delivery in Delivery,
            where: delivery.target_uri == ^URI.to_string(grantee),
            where: delivery.op == :revoke_cap,
            order_by: [desc: delivery.id],
            limit: 1
          )
        )

      assert delivery.status == :applied
      assert delivery.attempts == 1
    end

    test "async revoke stays pending outside a full ETS buffer and drains on ready" do
      grantee = target_user()
      {:ok, _} = Ezagent.SpawnRegistry.spawn(@admin_uri)
      {:ok, pid} = Ezagent.SpawnRegistry.spawn(grantee)
      Ezagent.ReadyGate.await(@admin_uri, 2_000)
      Ezagent.ReadyGate.await(grantee, 2_000)

      assert :ok = Grant.grant_cap(grantee, concrete_cap(), {:held_by, @admin_uri})
      assert cap_present?(grantee)

      :ok = Ezagent.ReadyGate.put(grantee, :not_ready)

      for index <- 1..Ezagent.PendingDelivery.max_per_uri() do
        :ok = Ezagent.PendingDelivery.buffer(grantee, {:unrelated, index})
      end

      assert :ok =
               Grant.revoke_cap_via_router(
                 grantee,
                 concrete_cap(),
                 {:held_by, @admin_uri},
                 :async
               )

      assert Ezagent.PendingDelivery.buffer_size(grantee) ==
               Ezagent.PendingDelivery.max_per_uri()

      delivery =
        Repo.one!(
          from(delivery in Delivery,
            where: delivery.target_uri == ^URI.to_string(grantee),
            where: delivery.op == :revoke_cap,
            order_by: [desc: delivery.id],
            limit: 1
          )
        )

      assert delivery.status == :pending
      assert cap_present_in_slice?(grantee)

      assert length(Ezagent.PendingDelivery.flush(grantee)) ==
               Ezagent.PendingDelivery.max_per_uri()

      assert :ready =
               Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(
                 URI.to_string(grantee),
                 pid
               )

      assert eventually(fn ->
               Repo.get!(Delivery, delivery.id).status == :applied and
                 not cap_present_in_slice?(grantee)
             end)
    end

    test "rule-based revoke still bypasses grant authz and only de-escalates" do
      grantee = target_user()
      configurer = Ezagent.URI.new!("entity://team-alpha/user/rule-configurer")
      {:ok, _} = Ezagent.SpawnRegistry.spawn(@admin_uri)
      {:ok, _} = Ezagent.SpawnRegistry.spawn(grantee)
      Ezagent.ReadyGate.await(@admin_uri, 2_000)
      Ezagent.ReadyGate.await(grantee, 2_000)

      assert :ok = Grant.grant_cap(grantee, concrete_cap(), {:held_by, @admin_uri})
      assert cap_present?(grantee)

      assert :ok =
               Grant.revoke_cap(grantee, concrete_cap(), {
                 :rule,
                 :session_membership_cleanup,
                 configurer
               })

      refute cap_present?(grantee)
    end
  end

  defp cap_present?(grantee) do
    Enum.any?(Ezagent.Identity.list_caps_for(grantee), fn cap ->
      cap.behavior == Ezagent.ActionSet.Template and
        cap.instance == {:within_workspace, ws()}
    end)
  end

  defp cap_present_in_slice?(grantee) do
    {:ok, slice} = Ezagent.Kind.get_slice(grantee, :identity)

    slice
    |> Ezagent.Kind.normalize_slice_view()
    |> Map.fetch!(:caps)
    |> Enum.any?(fn cap ->
      cap.behavior == Ezagent.ActionSet.Template and
        cap.instance == {:within_workspace, ws()}
    end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
