defmodule EzagentDomainInstanceMessage.UriQueryResolversTest do
  use EzagentCore.DataCase, async: false

  # DataCase's `using` block `import Ecto.Query`, whose `join/3` macro would
  # shadow this module's `defp join/3` session-join helper (#92). This module
  # uses no Ecto.Query macros, so exclude the colliding one.
  import Ecto.Query, except: [join: 3]

  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Credential.WorkspaceSharedSource
  alias Ezagent.Entity.{Session, User}

  alias Ezagent.{
    AgentFlavorAttributes,
    AgentPassiveAttributes,
    Agent.RecipeAttributes,
    Agent.RecipeResolver,
    Invocation,
    Kind,
    UriQuery
  }

  alias EzagentCore.Repo

  setup do
    # Shared sandbox provided by EzagentCore.DataCase (#92).
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())

    :ok
  end

  test "instance_message registers PR-A UriQuery resolvers at app boot" do
    agent_uri = URI.new!("entity://system/agent/cc_uri-query-unconfigured")
    session_uri = unique_session_uri("registered")

    assert :none = UriQuery.resolve(:flavor, agent_uri)
    assert :none = UriQuery.resolve(:orchestrator, session_uri)
    assert :none = UriQuery.resolve(:session_template, session_uri)
    assert :none = UriQuery.resolve(:member_by_role, {session_uri, "missing"})
    assert :none = UriQuery.resolve(:config_dir, agent_uri)
    assert :none = UriQuery.resolve(:recipe, agent_uri)
  end

  test "RF-7: :role resolves :none by default and the NAME once the attribute is stored" do
    agent_uri = Ezagent.URI.agent("system", "role-attr-#{System.unique_integer([:positive])}")

    on_exit(fn -> RecipeAttributes.delete(agent_uri) end)

    # No stored attribute + no snapshot → :none (no role).
    assert :none = UriQuery.resolve(:recipe, agent_uri)

    :ok = RecipeAttributes.put(agent_uri, "kanban-manager")
    assert {:ok, "kanban-manager"} = UriQuery.resolve(:recipe, agent_uri)
  end

  test "RF-7: :role layers ETS → durable snapshot (cold-restart fallback)" do
    agent_uri = URI.new!("entity://system/agent/role-durable-source")

    # No ETS entry → falls through to the durable :sandbox snapshot.
    assert :none = RecipeAttributes.fetch(agent_uri)

    assert {:ok, _} =
             Ezagent.SnapshotStore.write(
               agent_uri,
               %{sandbox: %{state: %{recipe: "kanban-manager"}}},
               kind_type: :agent
             )

    assert {:ok, "kanban-manager"} = UriQuery.resolve(:recipe, agent_uri)

    # A stored ETS entry is authoritative + stops the layering (fast path).
    on_exit(fn -> RecipeAttributes.delete(agent_uri) end)
    :ok = RecipeAttributes.put(agent_uri, "other-role")
    assert {:ok, "other-role"} = UriQuery.resolve(:recipe, agent_uri)
  end

  test "RF-7: list_by_recipe enumerates PERSISTED agents by role from the snapshot (cold-restart-safe)" do
    role = "rf7-list-#{System.unique_integer([:positive])}"
    a1 = URI.new!("entity://system/agent/rf7-list-a1-#{System.unique_integer([:positive])}")
    a2 = URI.new!("entity://system/agent/rf7-list-a2-#{System.unique_integer([:positive])}")
    other = URI.new!("entity://system/agent/rf7-list-other-#{System.unique_integer([:positive])}")

    # Persist three agents directly to the snapshot store (NO live Kind, NO ETS
    # entry) — exactly the DORMANT / post-restart state the kanban board faces.
    for {uri, r} <- [{a1, role}, {a2, role}, {other, "different-role"}] do
      assert {:ok, _} =
               Ezagent.SnapshotStore.write(uri, %{sandbox: %{state: %{recipe: r}}},
                 kind_type: :agent
               )
    end

    listed =
      RecipeResolver.list_by_recipe(role) |> Enum.map(&URI.to_string/1) |> MapSet.new()

    assert MapSet.subset?(MapSet.new([URI.to_string(a1), URI.to_string(a2)]), listed),
           "list_by_recipe did not enumerate the dormant role agents from the snapshot"

    refute URI.to_string(other) in listed,
           "list_by_recipe leaked an agent of a DIFFERENT role"
  end

  test "flavor resolves from stored launch attributes before the Agent Kind exists" do
    agent_uri =
      Ezagent.URI.agent("system", "uri-query-launch-#{System.unique_integer([:positive])}")

    on_exit(fn -> AgentFlavorAttributes.delete(agent_uri) end)
    :ok = AgentFlavorAttributes.put(agent_uri, "cc")

    assert {:ok, "cc"} = UriQuery.resolve(:flavor, agent_uri)
  end

  test "RF-6: :passive resolves false by default and true once the attribute is stored" do
    agent_uri =
      Ezagent.URI.agent("system", "passive-attr-#{System.unique_integer([:positive])}")

    on_exit(fn -> AgentPassiveAttributes.delete(agent_uri) end)

    # No stored attribute → principal actor (false), NOT :none — the gates need a
    # definite verdict and "unknown ⇒ principal" is the safe-by-default.
    assert {:ok, false} = UriQuery.resolve(:passive, agent_uri)

    :ok = AgentPassiveAttributes.put(agent_uri, true)
    assert {:ok, true} = UriQuery.resolve(:passive, agent_uri)

    :ok = AgentPassiveAttributes.put(agent_uri, false)
    assert {:ok, false} = UriQuery.resolve(:passive, agent_uri)
  end

  test "workspace_shared_credential_source resolves from workspace/flavor storage" do
    workspace_uri = URI.new!("workspace://system")
    source_uri = URI.new!("entity://system/agent/ws-service")

    assert :none =
             EzagentDomainInstanceMessage.UriQueryResolvers.resolve_workspace_shared_source(
               {workspace_uri, "cc"}
             )

    assert {:ok, _row} =
             %{
               workspace_uri: URI.to_string(workspace_uri),
               flavor: "cc",
               source_uri: URI.to_string(source_uri),
               set_by: URI.to_string(User.admin_uri())
             }
             |> WorkspaceSharedSource.changeset()
             |> Repo.insert()

    assert {:ok, ^source_uri} =
             EzagentDomainInstanceMessage.UriQueryResolvers.resolve_workspace_shared_source(
               {workspace_uri, "cc"}
             )
  end

  test "RF-5a: :passive layers ETS → durable snapshot (cold-restart, NOT fail-open)" do
    agent_uri = URI.new!("entity://system/agent/passive-durable-source")

    # No ETS entry → falls through to the durable :sandbox snapshot, which marks
    # the agent passive. This is the RF-6 fail-open fix: a passive data-actor
    # stays passive across a cold restart instead of reverting to a principal.
    assert :none = AgentPassiveAttributes.fetch(agent_uri)

    assert {:ok, _} =
             Ezagent.SnapshotStore.write(
               agent_uri,
               %{sandbox: %{state: %{passive: true}}},
               kind_type: :agent
             )

    assert {:ok, true} = UriQuery.resolve(:passive, agent_uri)

    # A stored ETS entry is authoritative + stops the layering (fast path).
    on_exit(fn -> AgentPassiveAttributes.delete(agent_uri) end)
    :ok = AgentPassiveAttributes.put(agent_uri, false)
    assert {:ok, false} = UriQuery.resolve(:passive, agent_uri)
  end

  test "config_dir resolves AgentTemplate content from durable snapshot" do
    template_uri = URI.new!("template://system/agent/ws-cc")

    assert {:ok, _} =
             Ezagent.SnapshotStore.write(
               template_uri,
               %{template: %{state: %{content: %{config_dir: "/tmp/ws-template-v2"}}}},
               kind_type: :agent_template
             )

    assert {:ok, "/tmp/ws-template-v2"} =
             EzagentDomainInstanceMessage.UriQueryResolvers.resolve_config_dir(template_uri)
  end

  test "config_dir resolves Agent sandbox config_dir_path from durable snapshot" do
    agent_uri = URI.new!("entity://system/agent/alice-source")

    assert {:ok, _} =
             Ezagent.SnapshotStore.write(
               agent_uri,
               %{sandbox: %{state: %{config_dir_path: "/tmp/source-v2"}}},
               kind_type: :agent
             )

    assert {:ok, "/tmp/source-v2"} =
             EzagentDomainInstanceMessage.UriQueryResolvers.resolve_config_dir(agent_uri)
  end

  # Resource-unification P1 (codex CRITICAL) — a bare config-dir resource:// URI
  # at :config_dir must NOT self-scope. There is no authenticated subject
  # alongside it, so deriving scope from the URI would be tautological; reject.
  test "config_dir rejects a BARE config-dir resource:// URI (no tautological self-scope)" do
    uri = Ezagent.URI.resource("victim", "cc-agents", "worker-1")

    assert {:error, :config_dir_resource_requires_scope} =
             EzagentDomainInstanceMessage.UriQueryResolvers.resolve_config_dir(uri)

    assert {:error, :config_dir_resource_requires_scope} =
             UriQuery.resolve(:config_dir, uri)
  end

  # A scoped {uri, scope} payload resolves config-dir types through the
  # FsResolver with an EXTERNAL authenticated scope. Foreign-<ws> fails loud;
  # matching-<ws> succeeds and is byte-identical to the raw Home layout.
  test "config_dir resolves a SCOPED config-dir resource payload; foreign-<ws> fails loud" do
    uri = Ezagent.URI.resource("acme", "cc-agents", "worker-1")

    assert {:ok, path} =
             EzagentDomainInstanceMessage.UriQueryResolvers.resolve_config_dir(
               {uri, %{workspace: "acme"}}
             )

    assert path == Path.join([Ezagent.Home.path("cc-agents"), "acme", "worker-1"])

    assert {:error, {:foreign_workspace, _}} =
             EzagentDomainInstanceMessage.UriQueryResolvers.resolve_config_dir(
               {uri, %{workspace: "attacker"}}
             )
  end

  # The socialware-config-object resource type stays self-authorizing — a bare
  # URI for it is NOT rejected by the config-dir guard (it delegates).
  test "config_dir still delegates a bare socialware-config-object resource URI (unchanged)" do
    uri =
      Ezagent.Socialware.ConfigProjection.object_uri(
        URI.new!("workspace://system"),
        Ecto.UUID.generate()
      )

    refute match?(
             {:error, :config_dir_resource_requires_scope},
             EzagentDomainInstanceMessage.UriQueryResolvers.resolve_config_dir(uri)
           )
  end

  # Resource-unification P1 (codex round-5 HIGH) — a bare NON-config-dir resource
  # URI (e.g. a future uploads layer) at :config_dir must fall through to `:none`,
  # NOT `{:error, _}`. The credential cascade treats `:none` as "skip this layer"
  # but `{:error, _}` as a FATAL abort; regressing an unrelated resource layer into
  # a hard error would break the cascade. Pre-P1 the socialware resolver returned
  # `:none` for any type it did not own — this preserves that.
  test "config_dir returns :none for a bare NON-config-dir resource:// URI (no cascade-abort regression)" do
    uri = Ezagent.URI.resource("team", "uploads", "file.bin")

    assert :none ==
             EzagentDomainInstanceMessage.UriQueryResolvers.resolve_config_dir(uri)

    assert :none == UriQuery.resolve(:config_dir, uri)
  end

  test "sandbox respawn class wins when multiple flavors share one template class" do
    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: "uri_query_noop_#{System.unique_integer([:positive])}",
        kind: Ezagent.Entity.Agent,
        template_class: Ezagent.PluginCc.Template.CcAgent
      })

    sandbox = %{
      template_class: Ezagent.PluginCc.Template.CcAgent,
      respawn_template_data: %{"class" => "cc.agent", "flavor" => "cc"}
    }

    # PR-9a (#53): flavor resolution moved to the core `Ezagent.AgentFlavorResolver`
    # (shared by the session `:flavor` resolver + the agent-domain delivery seam).
    assert {:ok, "cc"} = Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(sandbox)
  end

  test "session attributes resolve from the chat slice storage" do
    session_uri = spawn_session!("stored")
    session_template_uri = URI.new!("template://system/session/default@uri-query")
    orchestrator_uri = URI.new!("entity://system/agent/cc_uri-query-orchestrator")

    working_copy =
      SessionBehavior.default_template_working_copy()
      |> Map.put(:session_template_uri, session_template_uri)
      |> Map.put(:orchestrator_uri, orchestrator_uri)

    assert {:ok, _} = SessionBehavior.system_set_working_copy(session_uri, working_copy)

    assert {:ok, ^session_template_uri} = UriQuery.resolve(:session_template, session_uri)
    assert {:ok, ^orchestrator_uri} = UriQuery.resolve(:orchestrator, session_uri)
  end

  test "member_by_role resolves a role_name facet from session membership storage" do
    session_uri = spawn_session!("role")
    member_uri = unique_agent_uri("role-member")
    role_name = "reviewer"

    assert {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(member_uri, "cc")
    assert {:ok, %{members: members}} = join(session_uri, member_uri, role_name: role_name)

    assert member_uri in members
    assert {:ok, ^member_uri} = UriQuery.resolve(:member_by_role, {session_uri, role_name})
    assert :none = UriQuery.resolve(:member_by_role, {session_uri, "missing"})
  end

  test "agent_live_sessions lists live sessions containing an agent member" do
    session_uri = spawn_session!("agent-live")
    member_uri = unique_agent_uri("agent-live-member")
    other_uri = unique_agent_uri("agent-live-other")

    assert {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(member_uri, "cc")
    assert {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(other_uri, "cc")
    assert {:ok, %{members: members}} = join(session_uri, member_uri, role_name: "worker")
    assert member_uri in members

    assert {:ok, [^session_uri]} = EzagentDomainInstanceMessage.agent_live_sessions(member_uri)
    assert {:ok, true} = EzagentDomainInstanceMessage.agent_in_live_session?(member_uri)

    assert {:ok, []} = EzagentDomainInstanceMessage.agent_live_sessions(other_uri)
    assert {:ok, false} = EzagentDomainInstanceMessage.agent_in_live_session?(other_uri)
  end

  defp spawn_session!(label) do
    session_uri = unique_session_uri(label)

    assert {:ok, _pid} =
             Kind.spawn(Session, %{
               uri: session_uri,
               owner_uri: User.admin_uri(),
               behaviors: Ezagent.Entity.Session.behaviors()
             })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, URI.new!("workspace://system"))

    session_uri
  end

  defp join(session_uri, member_uri, facets) do
    Invocation.dispatch(%Invocation{
      target: URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
      mode: :call,
      args: Map.merge(%{member: member_uri}, Map.new(facets)),
      ctx: %{
        caller: User.admin_uri(),
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp unique_session_uri(label) do
    URI.new!("session://system/default/#{label}-#{System.unique_integer([:positive])}")
  end

  defp unique_agent_uri(label) do
    URI.new!("entity://system/agent/cc_#{label}-#{System.unique_integer([:positive])}")
  end
end
