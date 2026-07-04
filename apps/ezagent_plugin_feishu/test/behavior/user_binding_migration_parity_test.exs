defmodule EzagentPluginFeishu.Behavior.UserBindingMigrationParityTest do
  @moduledoc """
  Migration parity test for `EzagentPluginFeishu.Behavior.UserBinding`
  per SPEC `2026-05-28-router-behavior-kind-architecture.md` §7.3
  Level 1 (dispatch parity).

  This Behavior was migrated from the legacy `invoke/4` contract to
  the new `use Ezagent.ActionSet` + `handle_<action>/2` contract in
  Phase 2-f r3. The parity invariants checked here:

  - `Ezagent.ActionSet.new_style?/1` returns `true` for this module
  - The macro-derived legacy callbacks (`actions/0`, `interface/0`,
    `cap_subjects/0`) match the pre-migration shape
  - Custom `required_caps/0` preserves the `:workspace` axis (not the
    macro's `:any` default)
  - Each declared action has a matching `handle_<action>/2` clause
  - Per-action handlers return the new `{:ok, result, [effect]}` shape
  - State mutation arrives as a `{:set, key, value}` effect instead
    of an embedded `new_slice` return value
  - Read-only actions emit an empty effect list (slice unchanged)

  Replay parity (§7.3 Level 2) does NOT apply here — the durable
  store of truth for Feishu bindings is the `feishu_user_bindings`
  Ecto table, not the EventLog. The slice's `:bind_count` is an
  incidental counter that resets on Kind restart (documented in the
  Behavior's @moduledoc).
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.Behavior.UserBinding, as: BV

  @admin_uri Ezagent.URI.new!("entity://system/user/admin")
  @user_uri Ezagent.URI.new!("entity://team-alpha/user/alice")

  defp ctx(slice \\ %{bind_count: 0}) do
    %{
      caller: @admin_uri,
      caps: MapSet.new(),
      self_uri: Ezagent.URI.new!("workspace://team-alpha"),
      reply: :sync,
      read: fn key, default -> Map.get(slice, key, default) end
    }
  end

  describe "new-contract markers (SPEC §2.2)" do
    test "new_style?/1 returns true" do
      assert Ezagent.ActionSet.new_style?(BV)
    end

    test "__behavior__?/0 returns true (macro marker)" do
      assert BV.__behavior__?()
    end

    test "__action_names__/0 lists all declared actions" do
      names = BV.__action_names__()
      assert :bind in names
      assert :unbind in names
      assert :list_feishu_bindings in names
    end

    test "each action has a matching handle_<action>/2 export" do
      for action <- BV.__action_names__() do
        handler = String.to_atom("handle_#{action}")

        assert function_exported?(BV, handler, 2),
               "missing handler #{inspect(handler)}/2 for action :#{action}"
      end
    end

    test "__action_spec__/1 returns full per-action specs" do
      bind_spec = BV.__action_spec__(:bind)
      assert bind_spec.name == :bind
      assert bind_spec.args == %{open_id: :string, user_uri: :uri}
      assert bind_spec.returns == %{open_id: :string, user_uri: :string}
      assert bind_spec.caps == [:bind]
      assert bind_spec.modes == [:call]
      assert is_binary(bind_spec.description) and bind_spec.description != ""
    end
  end

  describe "legacy callbacks remain available (auto-derived where not overridden)" do
    test "actions/0 returns the declared action atoms" do
      assert BV.actions() |> Enum.sort() == [:bind, :list_feishu_bindings, :unbind]
    end

    test "interface/0 has an entry per action" do
      i = BV.interface()
      assert Map.keys(i) |> Enum.sort() == [:bind, :list_feishu_bindings, :unbind]

      for {_action, spec} <- i do
        assert is_binary(spec.description)
        assert is_map(spec.args)
        assert is_list(spec.modes)
      end
    end

    test "cap_subjects/0 lists action + description tuples" do
      subjects = BV.cap_subjects()
      assert length(subjects) == 3
      assert Enum.all?(subjects, fn {a, d} -> is_atom(a) and is_binary(d) end)
    end

    test "required_caps/0 preserves :workspace axis (custom override)" do
      # The macro-derived default would have axis `:any`; this
      # Behavior's `:workspace` axis is the production-correct shape
      # the CapabilityRegistry expects.
      for {_action, cap} <- BV.required_caps() do
        assert %Ezagent.Capability{kind: :workspace, behavior: BV} = cap
      end
    end

    test "state_slice/0 + init_slice/1 (Lifecycle two-container wiring)" do
      # Lifecycle (SPEC 2026-05-29 §2.3): `state_slice/0` is macro-emitted
      # from the `state_slice: :feishu_user_bindings` override;
      # `init_slice/1` returns the two-container slice (persistent
      # `bind_count` counter in `.state`, empty transients).
      assert BV.state_slice() == :feishu_user_bindings
      assert BV.init_slice(%{}) == %{state: %{bind_count: 0}, transients: %{}}
    end

    test "workspace_scoped? + data_owner shape preserved" do
      assert BV.workspace_scoped?() == false
      assert BV.data_owner(:any) == :any
    end
  end

  describe "new-contract handler return shape (SPEC §4.4)" do
    test "handle_bind/2 emits {:set, :bind_count, n+1} effect on success" do
      open_id = "ou_parity_bind_#{System.unique_integer([:positive])}"
      args = %{open_id: open_id, user_uri: @user_uri}

      {:ok, result, effects} = BV.handle_bind(args, ctx(%{bind_count: 7}))

      # Result shape matches the pre-migration return.
      assert result.open_id == open_id
      assert result.user_uri == URI.to_string(@user_uri)

      # Slice mutation arrives as an effect (NOT embedded in the return).
      assert {:set, :bind_count, 8} in effects
    end

    test "handle_bind/2 returns {:error, _} for malformed args (no effects)" do
      assert {:error, {:bad_args, _, _}} = BV.handle_bind(%{wrong: "shape"}, ctx())
    end

    test "handle_unbind/2 emits NO effects on success (slice unchanged)" do
      open_id = "ou_parity_unbind_#{System.unique_integer([:positive])}"

      # Seed
      {:ok, _, _} = BV.handle_bind(%{open_id: open_id, user_uri: @user_uri}, ctx())

      assert {:ok, %{unbound: ^open_id}, []} =
               BV.handle_unbind(%{open_id: open_id}, ctx())
    end

    test "handle_list_feishu_bindings/2 emits NO effects (read-only)" do
      assert {:ok, %{bindings: _}, []} =
               BV.handle_list_feishu_bindings(%{}, ctx())
    end
  end

  describe "effect-application produces the same final slice as pre-migration" do
    # Ezagent.ActionSet.apply_effects/2 is the framework reducer that
    # turns the handler's effect list into the new slice map. This
    # test verifies that running handle_bind's effects through the
    # reducer yields the same {:bind_count, n+1} shape the legacy
    # `invoke/4` returned as `new_slice`.
    test "apply_effects/2 on handle_bind result mutates :bind_count" do
      open_id = "ou_parity_apply_#{System.unique_integer([:positive])}"
      starting_slice = %{bind_count: 3, other_field: "preserved"}

      {:ok, _result, effects} =
        BV.handle_bind(%{open_id: open_id, user_uri: @user_uri}, ctx(starting_slice))

      {:ok, buckets} = Ezagent.ActionSet.apply_effects(effects, starting_slice)
      assert buckets.state[:bind_count] == 4
      # Other slice fields survive (apply_effects only sets declared keys).
      assert buckets.state[:other_field] == "preserved"
    end

    test "apply_effects/2 on handle_unbind result leaves slice unchanged" do
      open_id = "ou_parity_apply_unbind_#{System.unique_integer([:positive])}"
      starting_slice = %{bind_count: 5}

      # Seed
      {:ok, _, _} = BV.handle_bind(%{open_id: open_id, user_uri: @user_uri}, ctx(starting_slice))

      {:ok, _result, effects} = BV.handle_unbind(%{open_id: open_id}, ctx(starting_slice))

      {:ok, buckets} = Ezagent.ActionSet.apply_effects(effects, starting_slice)
      assert buckets.state == starting_slice
    end
  end
end
