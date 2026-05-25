defmodule EzagentPluginFeishu.Behavior.UserBindingTest do
  @moduledoc """
  Unit tests for the dispatch-backed UserBinding Behavior actions.

  Covers `invoke/4` directly (the dispatch step 5.5 cap check is
  exercised by the integration test in
  `apps/ezagent_cli/test/integration/cli_lv_cap_parity_test.exs`).
  These tests are the per-action-body coverage — same shape as
  `Ezagent.Behavior.RoutingTest`.
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.Behavior.UserBinding, as: BV
  alias EzagentPluginFeishu.UserBinding, as: UB

  @admin_uri URI.parse("entity://user/system/admin")
  @user_uri URI.parse("entity://user/team-alpha/alice")

  defp empty_slice, do: %{bind_count: 0}

  defp ctx do
    %{
      caller: @admin_uri,
      caps: MapSet.new(),
      self_uri: URI.parse("workspace://team-alpha"),
      reply: :sync
    }
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
        assert is_map(spec.returns)
        assert is_list(spec.modes)
      end
    end

    test "state_slice is :feishu_user_bindings" do
      assert BV.state_slice() == :feishu_user_bindings
    end

    test "init_slice returns starting counter" do
      assert BV.init_slice(%{}) == %{bind_count: 0}
    end

    test "workspace_scoped? is true (intra-workspace admin grants)" do
      assert BV.workspace_scoped?() == true
    end

    test "data_owner is :any (workspace-admin grantable)" do
      assert BV.data_owner(URI.parse("workspace://team-alpha")) == :any
      assert BV.data_owner(:any) == :any
    end
  end

  describe "invoke(:bind, ...)" do
    test "binds open_id to user_uri + applies BindingPolicy" do
      open_id = "ou_bv_bind_#{System.unique_integer([:positive])}"
      args = %{open_id: open_id, user_uri: @user_uri}

      {:ok, new_slice, %{open_id: ^open_id, user_uri: user_uri_str}} =
        BV.invoke(:bind, empty_slice(), args, ctx())

      assert user_uri_str == URI.to_string(@user_uri)
      assert new_slice.bind_count == 1

      # Storage layer reflects the binding.
      {:ok, %URI{} = u} = UB.resolve(open_id)
      assert URI.to_string(u) == URI.to_string(@user_uri)
    end

    test "accepts user_uri as a string too" do
      open_id = "ou_bv_str_#{System.unique_integer([:positive])}"
      args = %{open_id: open_id, user_uri: URI.to_string(@user_uri)}

      {:ok, _slice, _ret} = BV.invoke(:bind, empty_slice(), args, ctx())
      assert {:ok, _} = UB.resolve(open_id)
    end

    test "rejects empty open_id" do
      args = %{open_id: "", user_uri: @user_uri}
      assert {:error, _} = BV.invoke(:bind, empty_slice(), args, ctx())
    end

    test "rejects malformed args" do
      assert {:error, {:bad_args, _, _}} =
               BV.invoke(:bind, empty_slice(), %{wrong: "shape"}, ctx())
    end

    test "rebind silently replaces the prior user_uri" do
      open_id = "ou_bv_rebind_#{System.unique_integer([:positive])}"
      args1 = %{open_id: open_id, user_uri: @user_uri}
      args2 = %{open_id: open_id, user_uri: URI.parse("entity://user/team-alpha/bob")}

      {:ok, slice1, _} = BV.invoke(:bind, empty_slice(), args1, ctx())
      {:ok, _slice2, _} = BV.invoke(:bind, slice1, args2, ctx())

      {:ok, u} = UB.resolve(open_id)
      assert URI.to_string(u) == "entity://user/team-alpha/bob"
    end

    test "ctx.caller is recorded as bound_by (anti-impersonation)" do
      open_id = "ou_bv_bound_by_#{System.unique_integer([:positive])}"
      caller = URI.parse("entity://user/system/admin")

      args = %{open_id: open_id, user_uri: @user_uri}
      {:ok, _, _} = BV.invoke(:bind, empty_slice(), args, %{ctx() | caller: caller})

      [row] =
        EzagentCore.Repo.all(
          Ecto.Query.from(b in EzagentPluginFeishu.UserBinding, where: b.open_id == ^open_id)
        )

      assert row.bound_by == URI.to_string(caller)
    end
  end

  describe "invoke(:unbind, ...)" do
    test "removes an existing binding" do
      open_id = "ou_bv_unbind_#{System.unique_integer([:positive])}"
      # Seed
      {:ok, _, _} =
        BV.invoke(
          :bind,
          empty_slice(),
          %{open_id: open_id, user_uri: @user_uri},
          ctx()
        )

      assert {:ok, _, %{unbound: ^open_id}} =
               BV.invoke(:unbind, empty_slice(), %{open_id: open_id}, ctx())

      assert :error = UB.resolve(open_id)
    end

    test "returns :not_found for unknown open_id" do
      assert {:error, :not_found} =
               BV.invoke(:unbind, empty_slice(), %{open_id: "ou_never_existed"}, ctx())
    end

    test "rejects empty open_id" do
      assert {:error, _} =
               BV.invoke(:unbind, empty_slice(), %{open_id: ""}, ctx())
    end

    test "rejects malformed args" do
      assert {:error, {:bad_args, _, _}} =
               BV.invoke(:unbind, empty_slice(), %{wrong: "shape"}, ctx())
    end
  end

  describe "invoke(:list_feishu_bindings, ...)" do
    test "returns all bindings in the system" do
      open_id_a = "ou_bv_list_a_#{System.unique_integer([:positive])}"
      open_id_b = "ou_bv_list_b_#{System.unique_integer([:positive])}"

      {:ok, _, _} =
        BV.invoke(:bind, empty_slice(), %{open_id: open_id_a, user_uri: @user_uri}, ctx())

      {:ok, _, _} =
        BV.invoke(:bind, empty_slice(), %{open_id: open_id_b, user_uri: @user_uri}, ctx())

      {:ok, _, %{bindings: bindings}} =
        BV.invoke(:list_feishu_bindings, empty_slice(), %{}, ctx())

      open_ids = Enum.map(bindings, & &1.open_id)
      assert open_id_a in open_ids
      assert open_id_b in open_ids

      # Each row has the required shape.
      a_row = Enum.find(bindings, fn b -> b.open_id == open_id_a end)
      assert is_binary(a_row.user_uri)
      assert is_binary(a_row.bound_by)
      assert %DateTime{} = a_row.bound_at
    end

    test "returns empty list when no bindings exist (after sandbox reset)" do
      # The DataCase sandbox isolates per-test — at the start of THIS
      # test no rows exist.
      {:ok, _, %{bindings: bindings}} =
        BV.invoke(:list_feishu_bindings, empty_slice(), %{}, ctx())

      assert bindings == []
    end
  end
end
