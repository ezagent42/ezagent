defmodule EzagentDomainInstanceMessage.Integration.AgentFlavorResolverTest do
  @moduledoc """
  Invariant test for the agent-spawn resolver migration onto
  `Ezagent.AgentFlavorRegistry` (plugin authoring contract SPEC §6.3 /
  §7 row 3 / §9 item 7 — codex MEDIUM-5).

  Before this migration the `ezagent_domain_instance_message` `entity://` spawn
  resolver carried a hardcoded `flavor → {kind, template_class}` map —
  so "add a 6th agent-flavor plugin" actually required editing this
  non-plugin file. After the migration the resolver consults
  `Ezagent.AgentFlavorRegistry` (populated by each agent plugin's
  `agent_flavors/0` declaration through `Ezagent.Plugin.boot/1`).

  These assertions drive the PRODUCTION code path:
  `Ezagent.SpawnRegistry.spawn/1` → the chat plugin's `entity://`
  spawn fn → `spawn_agent/1` → flavor-prefix resolution → registry
  lookup. The test fails if anyone reintroduces a hardcoded flavor
  map.

  The test registers a SYNTHETIC flavor at runtime — proving SPEC §9
  item 7 (a brand-new agent flavor is resolvable with ZERO non-plugin
  file edited). It uses `Ezagent.Entity.Agent` (domain_instance_message's own
  Kind) so the test is self-sufficient regardless of which sibling
  plugin apps are started.
  """

  use ExUnit.Case, async: false

  alias Ezagent.{AgentFlavorRegistry, KindRegistry}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  describe "the resolver consults AgentFlavorRegistry" do
    test "registry IS the source — a flavor registered at runtime spawns a working agent" do
      # Proves SPEC §9 item 7: a NEW agent flavor is resolvable with
      # ZERO non-plugin file edited — registering it in
      # AgentFlavorRegistry is sufficient for the domain_instance_message resolver
      # to pick it up. If the old hardcoded `kind_module_from_flavor/1`
      # map were still in place, this synthetic flavor (absent from any
      # hardcoded clause) would fail to resolve.
      flavor = "xtest#{System.unique_integer([:positive])}"

      :ok =
        AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: Ezagent.PluginCc.Template.CcAgent
        })

      name = "#{flavor}_demo-#{System.unique_integer([:positive])}"
      uri = URI.parse("entity://agent/team-alpha/#{name}")

      # Drives the real resolver: SpawnRegistry → entity:// spawn fn →
      # spawn_agent → kind_module_from_flavor → AgentFlavorRegistry.
      assert {:ok, pid} = Ezagent.SpawnRegistry.spawn(uri)
      assert Process.alive?(pid)

      # The Kind that came up is exactly the one the registry named.
      assert {:ok, ^pid} = KindRegistry.lookup(uri)
      assert {:ok, %{kind: Ezagent.Entity.Agent}} = AgentFlavorRegistry.lookup(flavor)
    end

    test "an unregistered flavor resolves gracefully — no crash" do
      # Boot-ordering tolerance: a flavor whose plugin has not (yet)
      # registered yields `{:error, {:no_kind_module_for_agent, _}}`,
      # NOT a crash.
      uri = URI.parse("entity://agent/team-alpha/nosuchflavor_x")
      assert {:error, {:no_kind_module_for_agent, _}} = Ezagent.SpawnRegistry.spawn(uri)
    end

    test "the `test` fixture flavor still resolves (non-plugin fallback)" do
      # `test_*` agents are mention/routing test fixtures with no owning
      # plugin — kept as an explicit non-registry fallback to
      # `Ezagent.Entity.Agent`.
      uri = URI.parse("entity://agent/team-alpha/test_resolver-#{System.unique_integer([:positive])}")
      assert {:ok, pid} = Ezagent.SpawnRegistry.spawn(uri)
      assert Process.alive?(pid)
    end
  end
end
