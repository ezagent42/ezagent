defmodule EzagentDomainInstanceMessage.Integration.AgentFlavorResolverTest do
  @moduledoc """
  Invariant test for the agent-spawn resolver migration onto stored
  flavor lookup plus `Ezagent.AgentFlavorRegistry` (plugin authoring
  contract SPEC §6.3 / §7 row 3 / §9 item 7 — codex MEDIUM-5).

  Before this migration the `ezagent_domain_session` `entity://` spawn
  resolver carried a hardcoded `flavor → {kind, template_class}` map —
  so "add a 6th agent-flavor plugin" actually required editing this
  non-plugin file. After the migration the resolver consults
  `Ezagent.AgentFlavorRegistry` (populated by each agent plugin's
  `agent_flavors/0` declaration through `Ezagent.Plugin.boot/1`).

  These assertions drive the PRODUCTION code path:
  `Ezagent.SpawnRegistry.spawn/1` → the chat plugin's `entity://`
  spawn fn → `spawn_agent/1` → `UriQuery.resolve(:flavor, uri)` →
  registry lookup. The test fails if anyone reintroduces URI-prefix
  flavor parsing or a hardcoded flavor map.

  The test registers a SYNTHETIC flavor at runtime — proving SPEC §9
  item 7 (a brand-new agent flavor is resolvable with ZERO non-plugin
  file edited). It uses `Ezagent.Entity.Agent` (domain_instance_message's own
  Kind) so the test is self-sufficient regardless of which sibling
  plugin apps are started.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentFlavorRegistry, KindRegistry}

  setup do
    # Shared sandbox provided by EzagentCore.DataCase (#92).
    Ezagent.UriQuery.init()
    previous = :ets.lookup(Ezagent.UriQuery.table(), :flavor)

    on_exit(fn ->
      :ets.delete(Ezagent.UriQuery.table(), :flavor)

      for entry <- previous do
        :ets.insert(Ezagent.UriQuery.table(), entry)
      end
    end)

    :ok
  end

  describe "the resolver consults UriQuery and AgentFlavorRegistry" do
    test "stored flavor is the source — a runtime-registered flavor spawns a prefixless agent" do
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

      name = "demo-#{System.unique_integer([:positive])}"
      uri = Ezagent.URI.new!("entity://team-alpha/agent/#{name}")
      put_flavors(%{uri => flavor})

      # Drives the real resolver: SpawnRegistry → entity:// spawn fn →
      # spawn_agent → UriQuery flavor → AgentFlavorRegistry.
      assert {:ok, pid} = Ezagent.SpawnRegistry.spawn(uri)
      assert Process.alive?(pid)

      # The Kind that came up is exactly the one the registry named.
      assert {:ok, ^pid} = KindRegistry.lookup(uri)
      assert {:ok, %{kind: Ezagent.Entity.Agent}} = AgentFlavorRegistry.lookup(flavor)
    end

    test "an unregistered stored flavor resolves gracefully — no crash" do
      # Boot-ordering tolerance: a flavor whose plugin has not (yet)
      # registered yields `{:error, {:no_kind_module_for_agent, _}}`,
      # NOT a crash.
      uri = Ezagent.URI.new!("entity://team-alpha/agent/x")
      put_flavors(%{uri => "nosuchflavor"})

      assert {:error, {:no_kind_module_for_agent, _}} = Ezagent.SpawnRegistry.spawn(uri)
    end

    test "URI name prefix is ignored when no stored flavor exists" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_resolver-#{System.unique_integer([:positive])}"
        )

      assert {:error, {:no_kind_module_for_agent, _}} = Ezagent.SpawnRegistry.spawn(uri)
    end
  end

  defp put_flavors(flavors) when is_map(flavors) do
    by_uri =
      Map.new(flavors, fn {uri, flavor} ->
        {URI.to_string(uri), flavor}
      end)

    :ets.insert(Ezagent.UriQuery.table(), {:flavor, &resolve_test_flavor(&1, by_uri)})
  end

  defp resolve_test_flavor(%URI{} = uri, by_uri) do
    case Map.fetch(by_uri, URI.to_string(uri)) do
      {:ok, flavor} -> {:ok, flavor}
      :error -> :none
    end
  end
end
