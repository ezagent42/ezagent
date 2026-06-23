defmodule EzagentPluginEcho.Integration.PluginContractTest do
  @moduledoc """
  Acceptance test for the `Ezagent.Plugin` contract migration (plugin
  authoring contract SPEC §7 row 2 / §9 item 6).

  These assertions run against the REAL `EzagentPluginEcho.Application`
  — the umbrella starts it at boot, so `Ezagent.Plugin.boot/1` has
  already published every declaration by the time this test runs. No
  fixture plugin; this is the proof the contract works on the real
  echo plugin.
  """

  use ExUnit.Case, async: true

  setup do
    # The default echo agent (boot-spawned at `EzagentPluginEcho.Application`
    # start) is a node-global singleton. Under the full-umbrella `async`
    # run it can be transiently absent if a sibling test's sandbox owner
    # exited mid-snapshot and crashed the Kind.Server (a sandbox-model
    # artifact, not a production defect — prod uses the real pool, no
    # per-test owner). Re-spawn idempotently so the boot-resolution
    # assertion below starts from a live `echo_default`. This mirrors the
    # established pattern in `f1_direct_invoke_test.exs`'s setup;
    # `SpawnRegistry.spawn/1` returns the existing pid for an already-alive
    # Kind, so this is a no-op when the singleton survived.
    _ = Ezagent.SpawnRegistry.spawn(EzagentPluginEcho.Application.default_uri())
    :ok
  end

  test "echo plugin is registered in Ezagent.PluginRegistry after boot" do
    assert EzagentPluginEcho.Application in Ezagent.PluginRegistry.list_all(),
           "the real echo Application.start/2 → Ezagent.Plugin.boot/1 path " <>
             "must self-register the plugin in PluginRegistry"

    info = Ezagent.PluginRegistry.info("echo")
    assert info.slug == "echo"
    assert info.name == "Echo"
    assert is_binary(info.version) and info.version != ""
  end

  test "echo's agent_flavors/0 declaration landed in Ezagent.AgentFlavorRegistry" do
    assert {:ok, %{kind: kind, template_class: template_class}} =
             Ezagent.AgentFlavorRegistry.lookup("echo")

    assert kind == Ezagent.Entity.Agent
    assert template_class == Ezagent.PluginEcho.Template.EchoAgent
  end

  test "default echo agent has stored flavor attributes for boot spawn resolution" do
    default_uri = EzagentPluginEcho.Application.default_uri()

    assert {:ok, "echo"} = Ezagent.AgentFlavorAttributes.get(default_uri)
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(default_uri)
  end

  test "echo's behaviors/0 were published to BehaviorRegistry by boot/1" do
    # A3/A5: echo now rides Ezagent.Entity.Agent (Entity.Echo deleted).
    # The plugin registers {Agent, :say} → Behavior.Echo and {Agent, :write} →
    # Behavior.Pty. {Agent, :receive} is owned by Behavior.Agent.Receive
    # (registered by EzagentDomainAgent.Application — intentionally absent from
    # the echo plugin's behaviors/0 to avoid a capability-conflict boot crash).
    assert {:ok, Ezagent.Behavior.Echo} =
             Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Agent, :say)

    assert {:ok, Ezagent.Behavior.Agent.Receive} =
             Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Agent, :receive)

    assert {:ok, Ezagent.Behavior.Pty} =
             Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Agent, :write)
  end

  test "echo's echo.agent Template Class was published to TemplateRegistry" do
    assert {:ok, Ezagent.PluginEcho.Template.EchoAgent} =
             Ezagent.TemplateRegistry.lookup("echo.agent")
  end
end
