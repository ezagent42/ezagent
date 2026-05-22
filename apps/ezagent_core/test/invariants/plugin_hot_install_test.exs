defmodule Ezagent.Invariants.PluginHotInstallTest do
  @moduledoc """
  Phase 7 completion PR-6 closeout — the V1.4 gating test the audit
  (`docs/notes/phase-7-implementation-audit-2026-05-22.md` §V1-V5)
  named `plugin_hot_install_test` as MISSING.

  V1.4 contract: "dev writes a plugin → `mix ezagent.plugin.install` →
  Kinds + Behaviors reachable without a phx restart" (Decision #142 /
  D7-8). The install task's mechanism is `:application.load/1` +
  `:application.ensure_all_started/1`, which runs the plugin's
  `Ezagent.Plugin.boot/1` — the framework's two-phase boot that
  performs every `*Registry` registration the plugin declares.

  This test gates the **observable invariant** that mechanism delivers:
  a real plugin OTP app (`ezagent_plugin_echo`) that has gone through
  the boot path has its declared Behaviors / Template Classes / agent
  flavors **present in the live core registries** — i.e. reachable
  without a restart. It also pins the install task's idempotency:
  `:application.ensure_all_started/1` on an already-running plugin is a
  clean no-op (`{:ok, []}`), the success path the task relies on.

  Pure registry assertions — no tmp Mix fixture, no second BEAM node.
  The structural "task exists + documents D7-8" checks remain in
  `apps/ezagent_core/test/mix/tasks/ezagent.plugin.install_test.exs`;
  THIS file gates the runtime invariant.
  """

  use ExUnit.Case, async: true

  alias Ezagent.{AgentFlavorRegistry, BehaviorRegistry, TemplateRegistry}

  @plugin_app :ezagent_plugin_echo

  describe "the install mechanism — :application.ensure_all_started" do
    test "ensure_all_started on an already-running plugin is an idempotent no-op" do
      # `mix ezagent.plugin.install` calls `:application.ensure_all_started/1`
      # and treats `{:ok, started}` as success — `started == []` meaning
      # "already running". A second install of the same plugin must not
      # error. This is the install task's documented idempotency
      # (re-install / concurrent-install convergence).
      assert {:ok, started} = :application.ensure_all_started(@plugin_app)

      assert is_list(started),
             "ensure_all_started/1 must return {:ok, [apps]} — the install " <>
               "task's success path"

      assert @plugin_app not in started,
             "a re-install of an already-running plugin must report it as " <>
               "NOT newly-started (idempotent — no double-boot)"
    end

    test "the plugin app is loaded into the Application controller" do
      # `:application.load/1` registers the app from its `.app` file —
      # step 2 of the install task. An installed plugin is `loaded`.
      loaded_apps = Enum.map(Application.loaded_applications(), fn {app, _, _} -> app end)

      assert @plugin_app in loaded_apps,
             "#{@plugin_app} must be loaded — the install task's :application.load step"
    end
  end

  describe "declared Behaviors are reachable in BehaviorRegistry (no restart)" do
    test "the echo plugin's :say + :receive Behaviors resolve through BehaviorRegistry" do
      # `EzagentPluginEcho.Application.behaviors/0` declares
      # `{Ezagent.Entity.Echo, :say|:receive} → Ezagent.Behavior.Echo`.
      # After `Ezagent.Plugin.boot/1` these MUST be resolvable via
      # `BehaviorRegistry.lookup/2` — that IS "reachable without
      # restart".
      assert {:ok, Ezagent.Behavior.Echo} =
               BehaviorRegistry.lookup(Ezagent.Entity.Echo, :say),
             "the plugin's declared :say Behavior must be in BehaviorRegistry"

      assert {:ok, Ezagent.Behavior.Echo} =
               BehaviorRegistry.lookup(Ezagent.Entity.Echo, :receive),
             "the plugin's declared :receive Behavior must be in BehaviorRegistry"
    end
  end

  describe "declared Template Classes are reachable in TemplateRegistry (no restart)" do
    test "the echo plugin's `echo.agent` Template Class resolves through TemplateRegistry" do
      # `template_classes/0` declares `Ezagent.PluginEcho.Template.EchoAgent`;
      # its `template_name/0` is the registry key.
      name = Ezagent.PluginEcho.Template.EchoAgent.template_name()

      assert {:ok, Ezagent.PluginEcho.Template.EchoAgent} = TemplateRegistry.lookup(name),
             "the plugin's declared Template Class must be in TemplateRegistry " <>
               "under #{inspect(name)}"
    end
  end

  describe "declared agent flavors are reachable in AgentFlavorRegistry (no restart)" do
    test "the echo plugin's `echo` flavor resolves through AgentFlavorRegistry" do
      # `agent_flavors/0` declares flavor `"echo"` →
      # `{Ezagent.Entity.Echo, Ezagent.PluginEcho.Template.EchoAgent}`.
      assert {:ok, %{kind: Ezagent.Entity.Echo, template_class: tc}} =
               AgentFlavorRegistry.lookup("echo"),
             "the plugin's declared `echo` flavor must be in AgentFlavorRegistry"

      assert tc == Ezagent.PluginEcho.Template.EchoAgent
    end
  end
end
