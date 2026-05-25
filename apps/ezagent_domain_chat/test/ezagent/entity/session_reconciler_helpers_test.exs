defmodule Ezagent.Entity.SessionReconcilerHelpersTest do
  @moduledoc """
  Generator-reconciler PR-A — unit tests for the 4 Kind-idempotency
  helpers introduced by the SPEC §5 audit.

  Helpers under test:
  - `Ezagent.Entity.Session.derive_session_uri/3` (SPEC §7-1 Option A)
  - `Ezagent.Entity.Session.cap_equal_ignoring_metadata?/2` (codex rev-2 HIGH-1)
  - `Ezagent.Entity.Session.existing_routing_rule_for/4` (codex rev-2 HIGH-5)
  - `Ezagent.Entity.Session.worker_already_owned_by_us?/3` (codex rev-3 HIGH-1)
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Routing.RuleStore

  @default_ws URI.new!("workspace://team-alpha")

  defp uniq, do: System.unique_integer([:positive])

  describe "derive_session_uri/3 — SPEC §7-1 Option A determinism" do
    test "identical (template_content, owner) → identical URI" do
      content = %{name: "support-team", class: "generic"}
      owner = URI.parse("entity://user/team-alpha/alice")

      uri1 = Session.derive_session_uri(content, @default_ws, owner)
      uri2 = Session.derive_session_uri(content, @default_ws, owner)

      assert URI.to_string(uri1) == URI.to_string(uri2)
    end

    test "different owners → different URIs" do
      content = %{name: "team", class: "generic"}
      alice = URI.parse("entity://user/team-alpha/alice")
      bob = URI.parse("entity://user/team-alpha/bob")

      uri_a = Session.derive_session_uri(content, @default_ws, alice)
      uri_b = Session.derive_session_uri(content, @default_ws, bob)

      refute URI.to_string(uri_a) == URI.to_string(uri_b)
    end

    test "different templates → different URIs" do
      content_a = %{name: "team-a", class: "generic"}
      content_b = %{name: "team-b", class: "generic"}
      owner = URI.parse("entity://user/team-alpha/alice")

      uri_a = Session.derive_session_uri(content_a, @default_ws, owner)
      uri_b = Session.derive_session_uri(content_b, @default_ws, owner)

      refute URI.to_string(uri_a) == URI.to_string(uri_b)
    end

    test "workspace segment matches the resolved workspace name" do
      content = %{name: "team", class: "generic"}
      owner = URI.parse("entity://user/team-alpha/alice")
      ws = URI.new!("workspace://team-alpha")

      uri = Session.derive_session_uri(content, ws, owner)

      # session://<class>/<workspace>/<owner-template>
      assert uri.scheme == "session"
      assert uri.host == "generic"
      assert String.starts_with?(uri.path, "/team-alpha/")
    end
  end

  describe "cap_equal_ignoring_metadata?/2 — codex rev-2 HIGH-1" do
    defp base_cap(opts) do
      %Capability{
        kind: Keyword.get(opts, :kind, :session),
        behavior: Keyword.get(opts, :behavior, :any),
        instance: Keyword.get(opts, :instance, :any),
        workspace_uri: Keyword.get(opts, :workspace_uri, @default_ws),
        granted_by: Keyword.get(opts, :granted_by, URI.parse("entity://user/team-alpha/alice")),
        granted_at: Keyword.get(opts, :granted_at, DateTime.utc_now())
      }
    end

    test "same authority, different granted_at → true" do
      a = base_cap(granted_at: DateTime.utc_now())
      b = base_cap(granted_at: DateTime.add(DateTime.utc_now(), 60, :second))

      assert Session.cap_equal_ignoring_metadata?(a, b)
    end

    test "same authority, different granted_by → false (provenance matters)" do
      a = base_cap(granted_by: URI.parse("entity://user/team-alpha/alice"))
      b = base_cap(granted_by: URI.parse("entity://user/team-alpha/bob"))

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

  describe "existing_routing_rule_for/4 — codex rev-2 HIGH-5 full-contract probe" do
    @table EzagentDomainChat.Routing.MentionRouting

    test "exact match (matcher + receivers + scope + enabled + source) → {:found, _}" do
      marker = "helper-found-#{uniq()}"
      matcher = {:text_contains, marker}
      receivers = [URI.parse("entity://agent/team-alpha/worker-#{uniq()}")]

      assert {:ok, _row} =
               RuleStore.add(
                 @table,
                 matcher,
                 receivers,
                 User.admin_uri(),
                 workspace_uri: @default_ws,
                 source: RuleStore.system_default_source()
               )

      assert {:found, _row} =
               Session.existing_routing_rule_for(@table, matcher, receivers, @default_ws)
    end

    test "receivers differ → :not_found" do
      marker = "helper-recvdiff-#{uniq()}"
      matcher = {:text_contains, marker}
      inserted = [URI.parse("entity://agent/team-alpha/worker-a-#{uniq()}")]
      probed = [URI.parse("entity://agent/team-alpha/worker-b-#{uniq()}")]

      assert {:ok, _row} =
               RuleStore.add(
                 @table,
                 matcher,
                 inserted,
                 User.admin_uri(),
                 workspace_uri: @default_ws,
                 source: RuleStore.system_default_source()
               )

      assert :not_found =
               Session.existing_routing_rule_for(@table, matcher, probed, @default_ws)
    end

    test "workspace scope differs → :not_found" do
      marker = "helper-wsdiff-#{uniq()}"
      matcher = {:text_contains, marker}
      receivers = [URI.parse("entity://agent/team-alpha/worker-#{uniq()}")]
      other_ws = URI.new!("workspace://other-helper-#{uniq()}")

      assert {:ok, _row} =
               RuleStore.add(
                 @table,
                 matcher,
                 receivers,
                 User.admin_uri(),
                 workspace_uri: other_ws,
                 source: RuleStore.system_default_source()
               )

      assert :not_found =
               Session.existing_routing_rule_for(@table, matcher, receivers, @default_ws)
    end

    test "enabled == false but otherwise matches → {:disabled, _}" do
      marker = "helper-disabled-#{uniq()}"
      matcher = {:text_contains, marker}
      receivers = [URI.parse("entity://agent/team-alpha/worker-#{uniq()}")]

      assert {:ok, row} =
               RuleStore.add(
                 @table,
                 matcher,
                 receivers,
                 User.admin_uri(),
                 workspace_uri: @default_ws,
                 source: RuleStore.system_default_source()
               )

      # Disable the row directly via Ecto so we don't need the full
      # RuleStore admin API.
      Ecto.Changeset.change(row, %{enabled: false}) |> EzagentCore.Repo.update!()

      assert {:disabled, %{id: id}} =
               Session.existing_routing_rule_for(@table, matcher, receivers, @default_ws)

      assert id == row.id
    end

    test "source == admin → :not_found (operator's rule, not ours)" do
      marker = "helper-adminsource-#{uniq()}"
      matcher = {:text_contains, marker}
      receivers = [URI.parse("entity://agent/team-alpha/worker-#{uniq()}")]

      # Default source = "admin" (RuleStore.add/5 default)
      assert {:ok, _row} =
               RuleStore.add(@table, matcher, receivers, User.admin_uri(),
                 workspace_uri: @default_ws
               )

      assert :not_found =
               Session.existing_routing_rule_for(@table, matcher, receivers, @default_ws)
    end
  end

  describe "worker_already_owned_by_us?/3 — codex rev-3 HIGH-1 ownership predicate" do
    test "dead worker (KindRegistry miss) → false" do
      worker_uri = URI.parse("entity://agent/team-alpha/dead-worker-#{uniq()}")
      orch_uri = URI.parse("entity://agent/team-alpha/cc_orchestrator-x")

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

      worker_uri = URI.parse("entity://agent/team-alpha/#{flavor}_owned-#{uniq()}")
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(worker_uri)

      orch_uri = URI.parse("entity://agent/team-alpha/cc_orchestrator-ownerpred-#{uniq()}")
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

      worker_uri = URI.parse("entity://agent/team-alpha/#{flavor}_mis-#{uniq()}")
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(worker_uri)

      foreign_orch = URI.parse("entity://agent/team-alpha/cc_orchestrator-foreign-#{uniq()}")
      our_orch = URI.parse("entity://agent/team-alpha/cc_orchestrator-ours-#{uniq()}")

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

      worker_uri = URI.parse("entity://agent/team-alpha/#{flavor}_wsm-#{uniq()}")
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(worker_uri)

      orch_uri = URI.parse("entity://agent/team-alpha/cc_orchestrator-wsm-#{uniq()}")
      other_ws = URI.new!("workspace://elsewhere-#{uniq()}")

      :ok = Ezagent.AgentLineage.record(worker_uri, orch_uri)
      :ok = Ezagent.WorkspaceRegistry.bind(worker_uri, other_ws)

      refute Session.worker_already_owned_by_us?(worker_uri, orch_uri, @default_ws)
    end
  end
end
