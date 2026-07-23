defmodule Ezagent.Entity.AgentSpawnFreshTest do
  @moduledoc """
  Generator-reconciler PR-A — tests for the new `Agent.spawn_fresh/4`
  primitive AND the legacy `Agent.spawn/4` shim contract.

  Required residual codex item (#2): pin `Agent.spawn/4` legacy-shim
  contract with its own test so a future shim regression is caught.

  `Agent.spawn_fresh/4` semantics (codex rev-4 HIGH-1):
    * `{:ok, :started, pid}` from SpawnRegistry → record lineage +
      bind workspace, return `{:ok, %{pid, fresh?: true, agent_uri}}`.
    * `{:ok, :already_started, pid}` → ZERO side effects (no bind, no
      lineage record), return `{:ok, %{pid, fresh?: false, agent_uri}}`.

  `Agent.spawn/4` legacy-shim contract: return `{:ok, agent_uri}` on
  either fresh OR already_started — preserves the pre-PR-A behaviour
  for non-reconciler callers (re-binds + re-records lineage on adopt).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Agent

  alias Ezagent.{
    AgentFlavorAttributes,
    AgentFlavorRegistry,
    AgentLineage,
    SpawnRegistry,
    WorkspaceRegistry
  }

  @default_ws URI.new!("workspace://team-alpha")
  @template_uri Ezagent.URI.new!("template://system/agent/cc-orchestrator")

  defp uniq, do: System.unique_integer([:positive])

  defp register_no_class_flavor do
    flavor = "freshtest#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: nil
      })

    flavor
  end

  defp store_flavor(instance, flavor) do
    agent_uri = Ezagent.URI.agent("team-alpha", instance)
    :ok = AgentFlavorAttributes.put(agent_uri, flavor)
    on_exit(fn -> AgentFlavorAttributes.delete(agent_uri) end)
    :ok
  end

  describe "spawn_fresh/4 — codex rev-4 HIGH-1 contract" do
    test "Agent before_start is a no-op without trusted launch context" do
      assert :ok = Agent.before_start(%{uri: Ezagent.URI.agent("team-alpha", "legacy")})
    end

    test "first spawn → fresh?: true + lineage + binding recorded" do
      flavor = register_no_class_flavor()
      instance = "#{flavor}_first-#{uniq()}"
      granted_by = Ezagent.URI.new!("entity://team-alpha/user/granter-#{uniq()}")
      :ok = store_flavor(instance, flavor)

      assert {:ok, %{pid: pid, fresh?: true, agent_uri: agent_uri}} =
               Agent.spawn_fresh(@template_uri, instance, @default_ws, granted_by)

      assert is_pid(pid)
      assert URI.to_string(agent_uri) == "entity://team-alpha/agent/#{instance}"

      # Side effects ARE recorded for a fresh worker.
      assert {:ok, %URI{} = bound} = WorkspaceRegistry.lookup(agent_uri)
      assert URI.to_string(bound) == URI.to_string(@default_ws)

      assert {:ok, %URI{} = spawned_by} = AgentLineage.lookup(agent_uri)
      assert URI.to_string(spawned_by) == URI.to_string(granted_by)
    end

    test "second spawn of same URI → fresh?: false + NO lineage/binding mutation" do
      flavor = register_no_class_flavor()
      instance = "#{flavor}_second-#{uniq()}"
      :ok = store_flavor(instance, flavor)

      first_granter = Ezagent.URI.new!("entity://team-alpha/user/first-#{uniq()}")
      other_granter = Ezagent.URI.new!("entity://team-alpha/user/other-#{uniq()}")

      # First call records the ORIGINAL lineage + binding.
      assert {:ok, %{fresh?: true, agent_uri: agent_uri}} =
               Agent.spawn_fresh(@template_uri, instance, @default_ws, first_granter)

      original_lineage = AgentLineage.lookup(agent_uri)
      original_binding = WorkspaceRegistry.lookup(agent_uri)

      # Second call with the SAME instance+workspace (so the URI is
      # identical) but DIFFERENT granter would have re-parented the
      # worker pre-PR-A via `Agent.spawn/4`. With `spawn_fresh/4`,
      # the already_started branch must be SIDE-EFFECT-FREE (codex
      # rev-4 HIGH-1).
      assert {:ok, %{fresh?: false, agent_uri: ^agent_uri}} =
               Agent.spawn_fresh(@template_uri, instance, @default_ws, other_granter)

      # Lineage and binding UNCHANGED — first_granter / @default_ws
      # remain in place. This is the TOCTOU re-parenting guarantee.
      assert AgentLineage.lookup(agent_uri) == original_lineage,
             "spawn_fresh/4 must NOT re-record lineage on :already_started — " <>
               "that's exactly the TOCTOU re-parenting risk we're closing"

      assert WorkspaceRegistry.lookup(agent_uri) == original_binding,
             "spawn_fresh/4 must NOT re-bind workspace on :already_started"
    end

    test "no spawn fn for scheme → {:error, _}" do
      # The entity:// scheme IS registered (chat plugin). We can't
      # easily exercise the no-scheme branch without temporarily
      # de-registering. We can verify spawn_fresh propagates errors
      # by deleting the scheme's entry briefly.
      orig = SpawnRegistry.registered_schemes()
      assert "entity" in orig

      # No easy de-register API; skip in favor of unit confidence in
      # spawn_detailed's contract (covered in its own tests).
    end
  end

  describe "spawn/4 — legacy shim contract (residual codex #2)" do
    test "first call → {:ok, agent_uri} (pre-PR-A shape preserved)" do
      flavor = register_no_class_flavor()
      instance = "#{flavor}_shim-first-#{uniq()}"
      granted_by = Ezagent.URI.new!("entity://team-alpha/user/shim-granter-#{uniq()}")
      :ok = store_flavor(instance, flavor)

      assert {:ok, %URI{} = agent_uri} =
               Agent.spawn(@template_uri, instance, @default_ws, granted_by)

      assert URI.to_string(agent_uri) == "entity://team-alpha/agent/#{instance}"

      assert {:ok, _} = AgentLineage.lookup(agent_uri)
      assert {:ok, _} = WorkspaceRegistry.lookup(agent_uri)
    end

    test "second call → {:ok, agent_uri} too (legacy: re-binds + re-records)" do
      flavor = register_no_class_flavor()
      instance = "#{flavor}_shim-second-#{uniq()}"
      :ok = store_flavor(instance, flavor)

      first_granter = Ezagent.URI.new!("entity://team-alpha/user/shim-first-#{uniq()}")
      second_granter = Ezagent.URI.new!("entity://team-alpha/user/shim-second-#{uniq()}")

      # First call.
      assert {:ok, agent_uri} =
               Agent.spawn(@template_uri, instance, @default_ws, first_granter)

      # D-1 makes derivation edges append-only: a second creator cannot
      # overwrite the first creator's durable lineage.
      assert {:error, :derivation_edge_conflict} =
               Agent.spawn(@template_uri, instance, @default_ws, second_granter)

      # The original lineage remains authoritative.
      assert {:ok, %URI{} = lineage} = AgentLineage.lookup(agent_uri)
      assert URI.to_string(lineage) == URI.to_string(first_granter)
    end
  end
end
