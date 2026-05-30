defmodule EzagentPluginFeishu.Behavior.FeishuAllowMigrationParityTest do
  @moduledoc """
  Migration parity test for
  `EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow` per
  SPEC `2026-05-28-router-behavior-kind-architecture.md` §7.3
  Level 1 (dispatch parity).

  Cap-only marker Behavior — `dispatchable?/0 == false`, used only as
  the per-adapter Cap 2 marker that `Ezagent.ExternalMirror.bind/4`
  Check 2 matches against. The migration moves this from legacy
  `@behaviour Ezagent.Behavior` to the new `use Ezagent.Behavior` +
  declarative `action/3` shape with a raising `handle_allow_feishu/2`
  (semantically a no-op — the handler must exist for the macro
  invariant but is never invoked because `dispatchable?/0 == false`
  prevents routing).
  """
  use ExUnit.Case, async: true

  alias EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow, as: Allow

  describe "new-contract markers (SPEC §2.2)" do
    test "new_style?/1 returns true" do
      assert Ezagent.Behavior.new_style?(Allow)
    end

    test "__behavior__?/0 returns true" do
      assert Allow.__behavior__?()
    end

    test "__action_names__/0 lists [:allow_feishu]" do
      assert Allow.__action_names__() == [:allow_feishu]
    end

    test "handle_allow_feishu/2 is exported (required by macro invariant)" do
      assert function_exported?(Allow, :handle_allow_feishu, 2)
    end
  end

  describe "cap-only marker preserved" do
    test "dispatchable?/0 returns false (cap-only marker)" do
      assert Allow.dispatchable?() == false
    end

    test "required_caps/0 uses the :session axis (custom override)" do
      # The macro-derived default would be `:any`; this Behavior must
      # keep `:session` so the CapabilityRegistry matches Check 2 in
      # `Ezagent.ExternalMirror.bind/4`.
      caps = Allow.required_caps()

      assert %Ezagent.Capability{kind: :session, behavior: Allow, action: :allow_feishu} =
               caps[:allow_feishu]
    end

    test "data_owner/1 returns :any (workspace-admin grantable)" do
      assert Allow.data_owner(:any) == :any
      assert Allow.data_owner(URI.parse("session://default/team-alpha/main")) == :any
    end

    test "handle_allow_feishu/2 raises if ever invoked (defence in depth)" do
      # Cap-only Behaviors must never be reached at dispatch time —
      # `dispatchable?/0 == false` prevents routing. If a regression
      # ever exposes this handler, the raise stops the dispatch with
      # a clear message instead of silently mis-behaving.
      assert_raise RuntimeError, ~r/cap-only/, fn ->
        Allow.handle_allow_feishu(%{}, %{})
      end
    end
  end

  describe "legacy callbacks remain available" do
    test "actions/0, interface/0, cap_subjects/0 all defined" do
      assert Allow.actions() == [:allow_feishu]
      assert Map.has_key?(Allow.interface(), :allow_feishu)
      assert [{:allow_feishu, desc}] = Allow.cap_subjects()
      assert is_binary(desc) and desc != ""
    end

    test "state_slice/0 + init_slice/1 (Lifecycle two-container wiring)" do
      # Lifecycle (SPEC 2026-05-29 §2.3): `state_slice/0` is macro-emitted
      # from the `state_slice: :external_adapter_feishu` override;
      # `init_slice/1` returns the two-container slice (empty state — this
      # marker holds none — and empty transients).
      assert Allow.state_slice() == :external_adapter_feishu
      assert Allow.init_slice(%{}) == %{state: %{}, transients: %{}}
    end
  end
end
