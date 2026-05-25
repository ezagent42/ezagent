defmodule EzagentPluginFeishu.Integration.PluginContractTest do
  @moduledoc """
  Acceptance test for the `Ezagent.Plugin` contract migration (plugin
  authoring contract SPEC §7 row 3 / §9 item 6).

  These assertions run against the REAL `EzagentPluginFeishu.Application`
  — the umbrella starts it at boot, so `Ezagent.Plugin.boot/1` has
  already published every declaration by the time this test runs.
  """

  use ExUnit.Case, async: true

  test "feishu plugin is registered in Ezagent.PluginRegistry after boot" do
    assert EzagentPluginFeishu.Application in Ezagent.PluginRegistry.list_all(),
           "the real feishu Application.start/2 → Ezagent.Plugin.boot/1 " <>
             "path must self-register the plugin in PluginRegistry"

    info = Ezagent.PluginRegistry.info("feishu")
    assert info.slug == "feishu"
    assert info.name == "Feishu (Lark)"
    assert is_binary(info.version) and info.version != ""
  end

  test "feishu's behaviors/0 published the per-adapter Allow cap Behavior on Session" do
    # PR-EM-6 reshape (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
    # §9) — feishu's Session-Kind Behavior registration shrinks to the
    # per-adapter Allow cap marker (`:allow_feishu`). The old
    # `FeishuOutbound` `:notify_external` registration was retired —
    # outbound chat fan-out flows generically via the ExternalMirror
    # Domain (Session Publisher → Worker → Adapter+Binding).
    alias EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow, as: FeishuAllow

    for action <- FeishuAllow.actions() do
      assert {:ok, %{behavior: FeishuAllow, kind: Ezagent.Entity.Session}} =
               Ezagent.CapabilityRegistry.lookup_subject(Ezagent.Entity.Session, action),
             "expected (Session, #{inspect(action)}) → FeishuAllow registered as a cap subject"
    end
  end

  test "feishu's adapters/0 declares the FeishuAdapter + FeishuChatBinding pair" do
    # PR-EM-6 (SPEC §5.1 + §9 PR-EM-6) — the new declarative
    # adapter+binding contract. Grill-5 enforces the bidirectional
    # match at `mix compile` time; this test verifies the runtime
    # registration succeeded by querying both registries.
    assert {:ok, EzagentPluginFeishu.FeishuAdapter} =
             Ezagent.ExternalMirror.AdapterRegistry.lookup("feishu")

    assert {:ok, EzagentPluginFeishu.FeishuChatBinding} =
             Ezagent.ExternalMirror.BindingRegistry.lookup("feishu")
  end

  test "feishu declares NO spawns/0 — it owns no top-level scheme (SPEC v2 §5.8)" do
    # The `feishu://` scheme was deleted in PR #143. The plugin's
    # spawns/0 keeps the `use Ezagent.Plugin` default [].
    assert EzagentPluginFeishu.Application.spawns() == []
  end

  test "feishu declares NO agent_flavors/0 — it is not an agent plugin" do
    assert EzagentPluginFeishu.Application.agent_flavors() == []
  end

  test "feishu declares a :route config_surface to the Bindings page" do
    assert %{kind: :route, path: "/plugins/feishu/bindings", label: "Bindings"} =
             EzagentPluginFeishu.Application.config_surface()
  end
end
