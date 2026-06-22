defmodule EzagentDomainInstanceMessage.UriQueryResolversTest do
  use ExUnit.Case, async: false

  alias Ezagent.Behavior.Session, as: SessionBehavior
  alias Ezagent.Credential.WorkspaceSharedSource
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.{AgentFlavorAttributes, Invocation, Kind, UriQuery}
  alias EzagentCore.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

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
  end

  test "flavor resolves from stored launch attributes before the Agent Kind exists" do
    agent_uri =
      Ezagent.URI.agent("system", "uri-query-launch-#{System.unique_integer([:positive])}")

    on_exit(fn -> AgentFlavorAttributes.delete(agent_uri) end)
    :ok = AgentFlavorAttributes.put(agent_uri, "cc")

    assert {:ok, "cc"} = UriQuery.resolve(:flavor, agent_uri)
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
    uri = Ezagent.Socialware.ConfigProjection.object_uri(URI.new!("workspace://system"), Ecto.UUID.generate())

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
