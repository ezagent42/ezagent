defmodule Ezagent.Entity.SessionReconcilerHelpersTest do
  @moduledoc """
  Unit tests for the Kind-idempotency / ownership helpers KEPT on
  `Ezagent.Entity.Session` after the 2026-05-31 orchestrator-startup-
  atomicity pass deleted the dead Generator tree.

  Helpers under test (the Generator-only `derive_session_uri/3` +
  `existing_routing_rule_for/4` describe blocks were removed with the
  functions they covered):
  - `Ezagent.Entity.Session.cap_equal_ignoring_metadata?/2` (codex rev-2 HIGH-1)
  - `Ezagent.Entity.Session.worker_already_owned_by_us?/3` (codex rev-3 HIGH-1)
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Entity.Session

  @default_ws URI.new!("workspace://team-alpha")

  defp uniq, do: System.unique_integer([:positive])

  defp store_flavor(worker_uri, flavor) do
    :ok = Ezagent.AgentFlavorAttributes.put(worker_uri, flavor)
    on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(worker_uri) end)
    :ok
  end

  describe "cap_equal_ignoring_metadata?/2 — codex rev-2 HIGH-1" do
    defp base_cap(opts) do
      %Capability{
        kind: Keyword.get(opts, :kind, :session),
        behavior: Keyword.get(opts, :behavior, :any),
        instance: Keyword.get(opts, :instance, :any),
        workspace_uri: Keyword.get(opts, :workspace_uri, @default_ws),
        granted_by:
          Keyword.get(opts, :granted_by, Ezagent.URI.new!("entity://team-alpha/user/alice")),
        granted_at: Keyword.get(opts, :granted_at, DateTime.utc_now())
      }
    end

    test "same authority, different granted_at → true" do
      a = base_cap(granted_at: DateTime.utc_now())
      b = base_cap(granted_at: DateTime.add(DateTime.utc_now(), 60, :second))

      assert Session.cap_equal_ignoring_metadata?(a, b)
    end

    test "same authority, different granted_by → false (provenance matters)" do
      a = base_cap(granted_by: Ezagent.URI.new!("entity://team-alpha/user/alice"))
      b = base_cap(granted_by: Ezagent.URI.new!("entity://team-alpha/user/bob"))

      refute Session.cap_equal_ignoring_metadata?(a, b)
    end

    test "different :instance → false" do
      a = base_cap(instance: :any)
      b = base_cap(instance: {:within_session, URI.new!("session://x/team-alpha/s1")})

      refute Session.cap_equal_ignoring_metadata?(a, b)
    end

    test "different :workspace_uri → false" do
      a = base_cap(workspace_uri: @default_ws)
      b = base_cap(workspace_uri: URI.new!("workspace://other"))

      refute Session.cap_equal_ignoring_metadata?(a, b)
    end
  end

  describe "worker_already_owned_by_us?/3 — codex rev-3 HIGH-1 ownership predicate" do
    test "dead worker (KindRegistry miss) → false" do
      worker_uri = Ezagent.URI.new!("entity://team-alpha/agent/dead-worker-#{uniq()}")
      orch_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orchestrator-x")

      refute Session.worker_already_owned_by_us?(worker_uri, orch_uri, @default_ws)
    end

    test "live worker + lineage match + workspace match → true" do
      # Spawn a real Agent Kind via SpawnRegistry to get a live URI.
      flavor = "ownerpred#{uniq()}"

      :ok =
        Ezagent.AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: nil
        })

      worker_uri = Ezagent.URI.new!("entity://team-alpha/agent/#{flavor}_owned-#{uniq()}")
      :ok = store_flavor(worker_uri, flavor)
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(worker_uri)

      orch_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orchestrator-ownerpred-#{uniq()}")
      :ok = Ezagent.AgentLineage.record(worker_uri, orch_uri)
      :ok = Ezagent.WorkspaceRegistry.bind(worker_uri, @default_ws)

      assert Session.worker_already_owned_by_us?(worker_uri, orch_uri, @default_ws)
    end

    test "live worker + lineage MISMATCH → false" do
      flavor = "ownerpredmis#{uniq()}"

      :ok =
        Ezagent.AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: nil
        })

      worker_uri = Ezagent.URI.new!("entity://team-alpha/agent/#{flavor}_mis-#{uniq()}")
      :ok = store_flavor(worker_uri, flavor)
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(worker_uri)

      foreign_orch =
        Ezagent.URI.new!("entity://team-alpha/agent/cc_orchestrator-foreign-#{uniq()}")

      our_orch = Ezagent.URI.new!("entity://team-alpha/agent/cc_orchestrator-ours-#{uniq()}")

      :ok = Ezagent.AgentLineage.record(worker_uri, foreign_orch)
      :ok = Ezagent.WorkspaceRegistry.bind(worker_uri, @default_ws)

      # Worker is alive + bound to our ws BUT lineage points elsewhere.
      refute Session.worker_already_owned_by_us?(worker_uri, our_orch, @default_ws)
    end

    test "live worker + workspace MISMATCH → false" do
      flavor = "ownerpredwsm#{uniq()}"

      :ok =
        Ezagent.AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: nil
        })

      worker_uri = Ezagent.URI.new!("entity://team-alpha/agent/#{flavor}_wsm-#{uniq()}")
      :ok = store_flavor(worker_uri, flavor)
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(worker_uri)

      orch_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orchestrator-wsm-#{uniq()}")
      other_ws = URI.new!("workspace://elsewhere-#{uniq()}")

      :ok = Ezagent.AgentLineage.record(worker_uri, orch_uri)
      :ok = Ezagent.WorkspaceRegistry.bind(worker_uri, other_ws)

      refute Session.worker_already_owned_by_us?(worker_uri, orch_uri, @default_ws)
    end
  end
end
