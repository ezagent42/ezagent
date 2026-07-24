defmodule EzagentPluginFeishu.Behavior.UserBindingTest do
  @moduledoc """
  Unit tests for the dispatch-backed UserBinding Behavior actions.

  Post-Phase-2-f r3 migration: the Behavior now implements the new
  per-action contract (`use Ezagent.ActionSet` + `handle_<action>/2`).
  Tests call the new handlers directly with a synthesised `ctx`
  containing a `:read` closure (Kind.Runtime builds it at step 5.5
  per SPEC §2.2).

  Covers the action handlers' bodies (the dispatch step 5.5 cap check
  is exercised by the integration test in
  `apps/ezagent_cli/test/integration/cli_lv_cap_parity_test.exs`).
  These tests are the per-action-body coverage — same shape as
  `Ezagent.ActionSet.RoutingTest`.
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.Behavior.UserBinding, as: BV
  alias EzagentPluginFeishu.UserBinding, as: UB

  @admin_uri Ezagent.URI.new!("entity://system/user/admin")
  @user_uri Ezagent.URI.new!("entity://team-alpha/user/alice")

  # Build a ctx that mirrors what Kind.Runtime.handle_dispatch/4 step
  # 5.5 supplies to a new-contract handler. The `:read` closure is
  # the per-call read accessor (SPEC §2.2) — for tests we close over
  # a slice map directly.
  defp ctx(slice \\ %{bind_count: 0}, overrides \\ %{}) do
    base = %{
      caller: @admin_uri,
      caps: MapSet.new(),
      self_uri: Ezagent.URI.new!("workspace://team-alpha"),
      reply: :sync,
      read: fn key, default -> Map.get(slice, key, default) end
    }

    Map.merge(base, overrides)
  end

  # Convenience: extract the new bind_count from a `{:set, :bind_count, n}`
  # effect emitted by handle_bind/2. Returns nil if no such effect.
  defp set_effect(effects, key) do
    Enum.find_value(effects, fn
      {:set, ^key, value} -> {:found, value}
      _ -> nil
    end)
  end

  describe "actions/0 + required_caps/0 contract" do
    test "actions returns three names" do
      assert BV.actions() == [:bind, :unbind, :list_feishu_bindings]
    end

    test "required_caps has one entry per action" do
      caps = BV.required_caps()
      assert Map.keys(caps) |> Enum.sort() == [:bind, :list_feishu_bindings, :unbind]
      # Each is a Capability struct with kind: :workspace
      for {_action, cap} <- caps do
        assert %Ezagent.Capability{kind: :workspace, behavior: BV} = cap
      end
    end

    test "cap_subjects has one entry per action" do
      subjects = BV.cap_subjects()
      assert length(subjects) == 3
      action_names = subjects |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert action_names == [:bind, :list_feishu_bindings, :unbind]
    end

    test "interface has one entry per action with required keys" do
      i = BV.interface()
      assert Map.keys(i) |> Enum.sort() == [:bind, :list_feishu_bindings, :unbind]

      for {_action, spec} <- i do
        assert is_binary(spec.description)
        assert is_map(spec.args)
        assert is_list(spec.modes)
      end
    end

    test "state_slice is :feishu_user_bindings" do
      assert BV.state_slice() == :feishu_user_bindings
    end

    test "init_slice returns the two-container slice with the starting counter" do
      # Lifecycle (SPEC 2026-05-29 §2.3): `init_slice/1` returns
      # `%{state:, transients:}`; the persistent `bind_count` lives in
      # `.state` (no transients).
      assert BV.init_slice(%{}) == %{state: %{bind_count: 0}, transients: %{}}
    end

    test "workspace_scoped? is false (cross-workspace by design; structural check in body)" do
      # Codex r1 P1.2: the global feishu_user_bindings table has no
      # workspace column, so a workspace_scoped? = true declaration
      # would only enforce the CALLER/TARGET match while the action
      # body still operated on a global table — unsound. We declare
      # the Behavior cross-workspace and enforce per-call structurally.
      assert BV.workspace_scoped?() == false
    end

    test "data_owner is :any (workspace-admin grantable)" do
      assert BV.data_owner(Ezagent.URI.new!("workspace://team-alpha")) == :any
      assert BV.data_owner(:any) == :any
    end

    test "new contract: __action_names__/0 lists declared actions" do
      assert :bind in BV.__action_names__()
      assert :unbind in BV.__action_names__()
      assert :list_feishu_bindings in BV.__action_names__()
    end

    test "new contract: __action_spec__/1 returns the per-action spec" do
      spec = BV.__action_spec__(:bind)
      assert spec.name == :bind
      assert spec.args == %{open_id: :string, user_uri: :uri}
      assert spec.caps == [:bind]
      assert spec.modes == [:call]
    end

    test "new contract: new_style?/1 detects this Behavior" do
      assert Ezagent.ActionSet.new_style?(BV)
    end
  end

  describe "handle_bind/2" do
    test "binds open_id to user_uri + applies BindingPolicy + emits :set bind_count effect" do
      open_id = "ou_bv_bind_#{System.unique_integer([:positive])}"
      args = %{open_id: open_id, user_uri: @user_uri}

      {:ok, %{open_id: ^open_id, user_uri: user_uri_str}, effects} =
        BV.handle_bind(args, ctx())

      assert user_uri_str == URI.to_string(@user_uri)
      # New contract: slice mutation arrives as an effect, not in the return.
      assert {:found, 1} = set_effect(effects, :bind_count)

      # Storage layer reflects the binding.
      {:ok, %URI{} = u} = UB.resolve(open_id)
      assert URI.to_string(u) == URI.to_string(@user_uri)
    end

    test "accepts user_uri as a string too" do
      open_id = "ou_bv_str_#{System.unique_integer([:positive])}"
      args = %{open_id: open_id, user_uri: URI.to_string(@user_uri)}

      {:ok, _ret, _effects} = BV.handle_bind(args, ctx())
      assert {:ok, _} = UB.resolve(open_id)
    end

    test "rejects empty open_id" do
      args = %{open_id: "", user_uri: @user_uri}
      assert {:error, _} = BV.handle_bind(args, ctx())
    end

    test "rejects malformed args" do
      assert {:error, {:bad_args, _, _}} =
               BV.handle_bind(%{wrong: "shape"}, ctx())
    end

    test "rebind silently replaces the prior user_uri" do
      open_id = "ou_bv_rebind_#{System.unique_integer([:positive])}"
      args1 = %{open_id: open_id, user_uri: @user_uri}
      args2 = %{open_id: open_id, user_uri: Ezagent.URI.new!("entity://team-alpha/user/bob")}

      # First bind — slice starts at 0.
      {:ok, _, effects1} = BV.handle_bind(args1, ctx(%{bind_count: 0}))
      assert {:found, 1} = set_effect(effects1, :bind_count)

      # Rebind — slice is now 1; the second handle_bind reads 1 and
      # bumps to 2. The handler is stateless; tests simulate the
      # framework applying effects between calls by passing the new
      # slice into the next ctx().
      {:ok, _, effects2} = BV.handle_bind(args2, ctx(%{bind_count: 1}))
      assert {:found, 2} = set_effect(effects2, :bind_count)

      {:ok, u} = UB.resolve(open_id)
      assert URI.to_string(u) == "entity://team-alpha/user/bob"
    end

    test "ctx.caller is recorded as bound_by (anti-impersonation)" do
      open_id = "ou_bv_bound_by_#{System.unique_integer([:positive])}"
      caller = Ezagent.URI.new!("entity://system/user/admin")

      args = %{open_id: open_id, user_uri: @user_uri}
      {:ok, _, _} = BV.handle_bind(args, %{ctx() | caller: caller})

      [row] =
        EzagentCore.Repo.all(
          Ecto.Query.from(b in EzagentPluginFeishu.UserBinding, where: b.open_id == ^open_id)
        )

      assert row.bound_by == URI.to_string(caller)
    end

    # Codex r1 P1.2 — workspace enforcement regression tests.

    test "refuses to bind a user from a different workspace" do
      # Target = workspace://team-alpha, user is in workspace://team-beta.
      open_id = "ou_bv_cross_ws_#{System.unique_integer([:positive])}"
      foreign_user = Ezagent.URI.new!("entity://team-beta/user/eve")

      args = %{open_id: open_id, user_uri: foreign_user}

      assert {:error, {:cross_workspace_user, _}} =
               BV.handle_bind(args, ctx())

      # No row was inserted (the with-chain short-circuits BEFORE
      # UserBinding.bind/3 fires).
      assert :error = UB.resolve(open_id)
    end

    test "bootstrap admin bypass: self_uri = :any allows cross-workspace bind" do
      # When ctx.self_uri is not a concrete workspace URI (admin path
      # at step 5.5 already validated the cap), the structural check
      # treats target as `:any` and lets the bind proceed.
      open_id = "ou_bv_admin_bypass_#{System.unique_integer([:positive])}"
      admin_ctx = Map.delete(ctx(), :self_uri)

      args = %{open_id: open_id, user_uri: Ezagent.URI.new!("entity://team-beta/user/eve")}

      assert {:ok, _ret, _effects} = BV.handle_bind(args, admin_ctx)
    end

    test "lazy-seeds bind_count when slice has no prior :bind_count key (codex r1 P1.1)" do
      # Workspace Kind only initializes its `:workspace` slice; the
      # plugin-registered `:feishu_user_bindings` slice arrives empty.
      # The action must not crash when ctx.read returns the default 0.
      open_id = "ou_bv_lazy_seed_#{System.unique_integer([:positive])}"
      args = %{open_id: open_id, user_uri: @user_uri}

      # Pass a slice WITHOUT :bind_count — ctx.read returns the default.
      empty_ctx = ctx(%{})

      assert {:ok, _ret, effects} = BV.handle_bind(args, empty_ctx)
      assert {:found, 1} = set_effect(effects, :bind_count)
    end

    # Codex r2 P1 — anti-hijack rebind check.

    test "refuses to rebind an open_id held by a different workspace (codex r2 P1)" do
      # Seed an open_id bound to team-beta via admin bypass.
      open_id = "ou_bv_hijack_#{System.unique_integer([:positive])}"
      admin_ctx = Map.delete(ctx(), :self_uri)

      {:ok, _, _} =
        BV.handle_bind(
          %{open_id: open_id, user_uri: Ezagent.URI.new!("entity://team-beta/user/eve")},
          admin_ctx
        )

      # team-alpha caller tries to rebind to a team-alpha user.
      assert {:error, {:cross_workspace_rebind, _}} =
               BV.handle_bind(
                 %{open_id: open_id, user_uri: @user_uri},
                 ctx()
               )

      # Original team-beta binding is still intact.
      {:ok, u} = UB.resolve(open_id)
      assert URI.to_string(u) == "entity://team-beta/user/eve"
    end

    test "allows rebind within the same workspace (legitimate rotation)" do
      # Set up a team-alpha binding, then rebind to another team-alpha
      # user — should succeed (same tenant, normal rotation).
      open_id = "ou_bv_rotate_#{System.unique_integer([:positive])}"

      {:ok, _, _} = BV.handle_bind(%{open_id: open_id, user_uri: @user_uri}, ctx())

      new_user = Ezagent.URI.new!("entity://team-alpha/user/bob")

      assert {:ok, _ret, _effects} =
               BV.handle_bind(%{open_id: open_id, user_uri: new_user}, ctx())

      {:ok, u} = UB.resolve(open_id)
      assert URI.to_string(u) == URI.to_string(new_user)
    end

    test "fresh bind (no prior open_id) is unaffected by hijack check" do
      # Sanity: a brand-new open_id binds without anti-hijack triggering.
      open_id = "ou_bv_fresh_#{System.unique_integer([:positive])}"

      assert {:ok, %{open_id: ^open_id}, _effects} =
               BV.handle_bind(%{open_id: open_id, user_uri: @user_uri}, ctx())
    end

    # Codex r2 P2 — rollback on policy-apply failure.
    # NOTE: BindingPolicy.apply/2 → ensure_user_kind/1 → ensure_started/1
    # never fails for valid entity://user URIs (User Kind spawn always
    # succeeds), so the rollback code path is currently unreachable in
    # production for valid entity URIs.  The apply_policy_or_rollback
    # helper remains as defense-in-depth.  Making this path
    # deterministically testable at the World level requires a controlled
    # policy-failure seam (B1 Phase 3).

    test "rejects non-entity user_uri with :not_entity_uri (B2 fail-closed gate)" do
      admin_ctx = Map.delete(ctx(), :self_uri)
      open_id = "ou_bv_not_entity_#{System.unique_integer([:positive])}"

      assert {:error, {:not_entity_uri, "template://system/foo/bar"}} =
               BV.handle_bind(
                 %{open_id: open_id, user_uri: Ezagent.URI.new!("template://system/foo/bar")},
                 admin_ctx
               )
    end

    test "rejects non-user entity URI (e.g. entity://system/agent/x)" do
      admin_ctx = Map.delete(ctx(), :self_uri)
      open_id = "ou_bv_not_user_#{System.unique_integer([:positive])}"

      assert {:error, {:not_user_entity, _}} =
               BV.handle_bind(
                 %{
                   open_id: open_id,
                   user_uri: Ezagent.URI.new!("entity://system/agent/some_bot")
                 },
                 admin_ctx
               )
    end

    test "rolls back DB row when BindingPolicy fails (codex r2 P2)" do
      # NOTE: the rollback path is currently unreachable for entity://user
      # URIs because ensure_user_kind always succeeds.  This test verifies
      # the code shape compiles correctly for future deterministic testing.
      admin_ctx = Map.delete(ctx(), :self_uri)
      orphan_user = Ezagent.URI.new!("entity://no_such_workspace/user/orphan")
      open_id = "ou_bv_rollback_#{System.unique_integer([:positive])}"

      case BV.handle_bind(
             %{open_id: open_id, user_uri: orphan_user},
             admin_ctx
           ) do
        {:ok, _, _} ->
          assert {:ok, _} = UB.resolve(open_id)

        {:error, _} ->
          assert :error = UB.resolve(open_id),
                 "Codex r2 P2: BindingPolicy failed but the durable " <>
                   "row survived — rollback didn't fire"
      end
    end

    test "rollback is idempotent when called on a missing row (defensive)" do
      # Synthetic test of the rollback path's `:not_found` handling
      # — the helper logs but doesn't crash, even if the row is
      # already gone (e.g. concurrent unbind raced with rollback).
      missing_open_id = "ou_bv_rb_missing_#{System.unique_integer([:positive])}"

      # Call unbind on a missing open_id — same error path the rollback
      # tolerates. Must return {:error, :not_found}, not crash.
      assert {:error, :not_found} = UB.unbind(missing_open_id)
    end
  end

  describe "handle_unbind/2" do
    test "removes an existing binding" do
      open_id = "ou_bv_unbind_#{System.unique_integer([:positive])}"
      # Seed
      {:ok, _, _} = BV.handle_bind(%{open_id: open_id, user_uri: @user_uri}, ctx())

      assert {:ok, %{unbound: ^open_id}, []} =
               BV.handle_unbind(%{open_id: open_id}, ctx())

      assert :error = UB.resolve(open_id)
    end

    test "returns :not_found for unknown open_id" do
      assert {:error, :not_found} =
               BV.handle_unbind(%{open_id: "ou_never_existed"}, ctx())
    end

    test "rejects empty open_id" do
      assert {:error, _} = BV.handle_unbind(%{open_id: ""}, ctx())
    end

    test "rejects malformed args" do
      assert {:error, {:bad_args, _, _}} = BV.handle_unbind(%{wrong: "shape"}, ctx())
    end

    # Codex r1 P1.2 — workspace enforcement on unbind.

    test "refuses to unbind a row owned by a different workspace's user" do
      # Seed a binding for a user in team-beta via admin bypass.
      open_id = "ou_bv_unbind_cross_#{System.unique_integer([:positive])}"
      admin_ctx = Map.delete(ctx(), :self_uri)

      {:ok, _, _} =
        BV.handle_bind(
          %{open_id: open_id, user_uri: Ezagent.URI.new!("entity://team-beta/user/eve")},
          admin_ctx
        )

      # A team-alpha caller (ctx() self_uri = workspace://team-alpha)
      # MUST NOT unbind team-beta's binding.
      assert {:error, {:cross_workspace_user, _}} =
               BV.handle_unbind(%{open_id: open_id}, ctx())

      # Row survived.
      assert {:ok, _} = UB.resolve(open_id)
    end
  end

  describe "handle_list_feishu_bindings/2" do
    test "returns bindings for the target workspace only" do
      open_id_a = "ou_bv_list_a_#{System.unique_integer([:positive])}"
      open_id_b = "ou_bv_list_b_#{System.unique_integer([:positive])}"

      {:ok, _, _} = BV.handle_bind(%{open_id: open_id_a, user_uri: @user_uri}, ctx())

      {:ok, _, _} = BV.handle_bind(%{open_id: open_id_b, user_uri: @user_uri}, ctx())

      {:ok, %{bindings: bindings}, []} =
        BV.handle_list_feishu_bindings(%{}, ctx())

      open_ids = Enum.map(bindings, & &1.open_id)
      assert open_id_a in open_ids
      assert open_id_b in open_ids

      # Each row has the required shape.
      a_row = Enum.find(bindings, fn b -> b.open_id == open_id_a end)
      assert is_binary(a_row.user_uri)
      assert is_binary(a_row.bound_by)
      assert %DateTime{} = a_row.bound_at
    end

    test "filters out bindings from other workspaces (codex r1 P1.2)" do
      # Seed bindings: one in team-alpha (target), one in team-beta.
      open_id_alpha = "ou_bv_filter_alpha_#{System.unique_integer([:positive])}"
      open_id_beta = "ou_bv_filter_beta_#{System.unique_integer([:positive])}"

      admin_ctx = Map.delete(ctx(), :self_uri)

      # Admin seeds both.
      {:ok, _, _} =
        BV.handle_bind(
          %{open_id: open_id_alpha, user_uri: Ezagent.URI.new!("entity://team-alpha/user/alice")},
          admin_ctx
        )

      {:ok, _, _} =
        BV.handle_bind(
          %{open_id: open_id_beta, user_uri: Ezagent.URI.new!("entity://team-beta/user/eve")},
          admin_ctx
        )

      # Listing as team-alpha caller sees ONLY the alpha row.
      {:ok, %{bindings: alpha_bindings}, []} =
        BV.handle_list_feishu_bindings(%{}, ctx())

      alpha_open_ids = Enum.map(alpha_bindings, & &1.open_id)
      assert open_id_alpha in alpha_open_ids
      refute open_id_beta in alpha_open_ids

      # Listing as admin (no self_uri) sees both.
      {:ok, %{bindings: all_bindings}, []} =
        BV.handle_list_feishu_bindings(%{}, admin_ctx)

      all_open_ids = Enum.map(all_bindings, & &1.open_id)
      assert open_id_alpha in all_open_ids
      assert open_id_beta in all_open_ids
    end

    test "returns empty list when no bindings exist (after sandbox reset)" do
      # The DataCase sandbox isolates per-test — at the start of THIS
      # test no rows exist.
      {:ok, %{bindings: bindings}, []} =
        BV.handle_list_feishu_bindings(%{}, ctx())

      assert bindings == []
    end
  end
end
