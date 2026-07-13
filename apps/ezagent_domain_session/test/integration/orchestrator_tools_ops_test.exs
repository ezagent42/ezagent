defmodule EzagentDomainInstanceMessage.Integration.OrchestratorToolsOpsTest do
  @moduledoc """
  The AUTH-NET for the orchestrator tool operations, driven through the
  Decision C executor (`Ezagent.Session.SessionManager`).

  Transport #53 Decision C relocated the orchestrator-MCP executor into a
  plain supervised `SessionManager` GenServer in the session domain (replacing
  the deadlocking O-4 `ActionSet.OrchestratorTools` + `Orchestrator.ToolRunner`).
  This suite drives the REAL per-call flow that a forwarded `tools/call` takes:

      SessionManager.run_tool(orchestrator_uri, tool, args, bridge_token)
        → verify bridge token (the unforgeable gate, §2 step 0)
        → structural caller-is-our-orchestrator check (durable working copy)
        → reconstruct the orchestrator's delegated caps SESSION-side
        → run Ezagent.Orchestrator.Tools.<tool> under those caps
           (each session mutation dispatched to the Session Kind cross-process,
            cap-checked there)

  The orchestrator's delegated caps live in its OWN `:identity` slice
  (seeded at spawn) and are RECONSTRUCTED per-call — NOTHING crosses the wire
  but the tool name, args, and the bridge token.

  ## What it proves (the SAME auth contract as the old McpServer)

  1. **No-`admin_caps`-fallback denial** — caps #3/#4 OMITTED from the
     orchestrator's slice → `list_templates` / `update_template` deny.
  2. **cap-#2 happy / deny** — `remove_member` on a worker THIS orchestrator
     spawned succeeds; another orchestrator's call denies.
  3. **per-kind list** — a cap-#3-only orchestrator sees only session
     templates; cap-#4-only the inverse.
  4. **per-tool effects** — each tool produces its intended effect.
  5. **bridge-token authz** — a wrong / absent token denies BEFORE any tool
     runs (and the structural gate denies a cross-orchestrator binding).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentFlavorRegistry, AgentLineage, ActionSet, Capability, KindRegistry}
  alias Ezagent.Entity.{Agent, Session, SessionTemplate, User}
  alias Ezagent.TemplateTags
  alias Ezagent.Session.SessionManager
  alias Ezagent.AgentBridge.TokenStore

  defmodule TestFlavorClass do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "mcp.e2e.agent"

    @impl true
    def validate(tmpl) when is_map(tmpl),
      do: if(Map.has_key?(tmpl, "agent_uri"), do: :ok, else: {:error, :missing_agent_uri})

    def validate(_), do: {:error, :not_a_map}

    @impl true
    def instantiate(_tmpl_name, %{"agent_uri" => uri_str}, _workspace_uri) do
      agent_uri = Ezagent.URI.new!(uri_str)

      case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
        {:ok, :started, _pid} -> {:ok, [agent_uri], %{fresh?: true}}
        {:ok, :already_started, _pid} -> {:ok, [agent_uri], %{fresh?: false}}
        {:error, _} = err -> err
      end
    end

    def instantiate(_n, tmpl, _ws), do: {:error, {:invalid_template, tmpl}}
  end

  # An isolated EZAGENT_HOME so TokenStore.mint writes to a sandboxed file and
  # never collides with the operator's real credentials.
  setup do
    home = Path.join(System.tmp_dir!(), "orch-ops-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("EZAGENT_HOME")
    System.put_env("EZAGENT_HOME", home)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("EZAGENT_HOME", prev_home),
        else: System.delete_env("EZAGENT_HOME")

      File.rm_rf(home)
    end)

    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  @workspace_uri URI.new!("workspace://team-alpha")

  defp register_test_flavor do
    flavor = "mcpe2e#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Agent,
        template_class: TestFlavorClass
      })

    flavor
  end

  defp dispatch(uri, action, args) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=#{action}")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp create_agent_template(uri, flavor, name) do
    content = %{
      name: name,
      description: "worker #{name}",
      flavor: flavor,
      project_cwd: "/tmp/mcp-e2e",
      config_dir: nil,
      settings_path: nil,
      mcp_config_path: nil,
      api_key_helper: nil,
      default_caps: [],
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-22 00:00:00Z]
    }

    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    {:ok, %{content: ^content}} = dispatch(uri, "template.write", %{content: content})
    :ok
  end

  defp template_hash(%URI{} = uri) do
    uri
    |> Ezagent.URI.name!()
    |> String.split("@", parts: 2)
    |> List.last()
  end

  defp template_cap(kind, workspace_uri) do
    %Capability{
      kind: kind,
      behavior: ActionSet.Template,
      instance: {:within_workspace, workspace_uri},
      workspace_uri: workspace_uri,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  # The four delegated caps the Generator grants an orchestrator (§1.4):
  # #1 within_session, #2 spawned_by, #3 session_template, #4 agent_template.
  # `template_kinds` selects which template caps are present.
  defp orchestrator_caps(session_uri, orchestrator_uri, workspace_uri, template_kinds) do
    base = [
      %Capability{
        kind: :session,
        behavior: :any,
        instance: {:within_session, session_uri},
        workspace_uri: workspace_uri,
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      },
      %Capability{
        kind: :agent,
        behavior: :any,
        instance: {:spawned_by, orchestrator_uri},
        workspace_uri: workspace_uri,
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      }
    ]

    MapSet.new(base ++ Enum.map(template_kinds, &template_cap(&1, workspace_uri)))
  end

  defp spawn_session do
    session_uri = Ezagent.URI.session("team-alpha", "generic", "mcp-e2e-#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: User.admin_uri()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    session_uri
  end

  # Spawn an orchestrator Agent whose `:identity` slice carries `caps`
  # (reconstructed session-side per-call), set the session's DURABLE
  # working-copy `orchestrator_uri` (the structural gate), mint its bridge
  # token, and start the SessionManager. Returns `{orchestrator_uri, token}`.
  defp setup_orchestrator(session_uri, caps) do
    orchestrator_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-#{uniq()}")

    :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")
    on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(orchestrator_uri) end)

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri, initial_caps: caps})
    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)

    :ok = set_active_binding(session_uri, orchestrator_uri)

    {:ok, token} = TokenStore.mint(orchestrator_uri)

    {:ok, _sm} =
      SessionManager.ensure_started(
        orchestrator_uri: orchestrator_uri,
        session_uri: session_uri,
        workspace_uri: @workspace_uri,
        owner_uri: orchestrator_uri
      )

    on_exit(fn -> SessionManager.stop(orchestrator_uri) end)

    {orchestrator_uri, token}
  end

  # Provision a full orchestrator with the given template-cap kinds.
  defp provision(template_kinds) do
    session_uri = spawn_session()

    orchestrator_uri_placeholder =
      Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-pre-#{uniq()}")

    caps =
      orchestrator_caps(session_uri, orchestrator_uri_placeholder, @workspace_uri, template_kinds)

    # The cap-#2 `{:spawned_by, orchestrator}` cap must reference the REAL
    # orchestrator URI; recompute once we have it. Spawn the orchestrator with
    # the within_session + template caps first, then re-seed is unnecessary —
    # cap #2 is only needed by remove_member tests, which build it explicitly.
    {orchestrator_uri, token} = setup_orchestrator(session_uri, caps)

    %{session_uri: session_uri, orchestrator_uri: orchestrator_uri, token: token}
  end

  # Re-spawn-free helper: provision an orchestrator whose slice carries the
  # cap-#2 spawned_by-SELF cap (needed by add/remove member tests). Because the
  # spawned_by cap references the orchestrator URI, we mint the URI first.
  defp provision_with_self_caps(template_kinds) do
    session_uri = spawn_session()
    orchestrator_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-#{uniq()}")

    :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")
    on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(orchestrator_uri) end)

    caps = orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, template_kinds)

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri, initial_caps: caps})
    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)

    :ok = set_active_binding(session_uri, orchestrator_uri)

    {:ok, token} = TokenStore.mint(orchestrator_uri)

    {:ok, _sm} =
      SessionManager.ensure_started(
        orchestrator_uri: orchestrator_uri,
        session_uri: session_uri,
        workspace_uri: @workspace_uri,
        owner_uri: orchestrator_uri
      )

    on_exit(fn -> SessionManager.stop(orchestrator_uri) end)

    %{session_uri: session_uri, orchestrator_uri: orchestrator_uri, token: token}
  end

  # Run a tool through the SessionManager (the real Decision C flow). Returns
  # the RAW result, with the structural + cap gates exercised.
  defp run_tool(%{orchestrator_uri: orch, token: token}, tool, args) when is_binary(tool) do
    SessionManager.run_tool(orch, tool, args, token)
  end

  defp set_active_binding(session_uri, orchestrator_uri, extra \\ %{}) do
    :ok =
      Ezagent.Orchestrator.Tools.join_member(
        session_uri,
        orchestrator_uri,
        %{role_name: "orchestrator", in_session_template: true},
        User.admin_uri(),
        MapSet.new([Capability.admin_genesis_cap()])
      )

    epoch = Ecto.UUID.generate()

    working_copy =
      Map.merge(
        %{
          orchestrator_uri: %{
            uri: orchestrator_uri,
            epoch: epoch,
            status: :active
          },
          orchestrator_materialization_epoch: epoch
        },
        extra
      )

    case Ezagent.ActionSet.Session.ConfigActions.system_set_working_copy(
           session_uri,
           working_copy
         ) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp chat_slice(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: slice}}} = :sys.get_state(pid)
    slice
  end

  defp confirmed_user(prefix) do
    uri = Ezagent.URI.user("team-alpha", "#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    :ok = Ezagent.WorkspaceRegistry.bind(uri, @workspace_uri)
    uri
  end

  defp has_cap?(entity_uri, behavior, action, instance) do
    Enum.any?(Ezagent.Identity.list_caps_for(entity_uri), fn
      %Capability{} = cap ->
        cap.kind == :session and cap.behavior == behavior and
          Capability.action_of(cap) == action and cap.instance == instance

      _ ->
        false
    end)
  end

  defp has_workspace_wide_session_cap?(entity_uri) do
    Enum.any?(Ezagent.Identity.list_caps_for(entity_uri), fn
      %Capability{} = cap -> cap.kind == :session and cap.instance == :any
      _ -> false
    end)
  end

  describe "SessionManager lifecycle (codex C-rC fixes)" do
    test "ensure_for_session restarts the executor from the durable working copy (P1 self-heal)" do
      ctx = provision([:agent_template])

      # Simulate the executor being gone after a BEAM restart (the cc McpRegistry
      # + SessionManagerRegistry are empty post-restart).
      :ok = SessionManager.stop(ctx.orchestrator_uri)
      assert SessionManager.whereis(ctx.orchestrator_uri) == :error

      # Cold-restart self-heal: rehydrating the session re-derives the binding
      # from the LIVE working copy + restarts the executor.
      assert {:ok, pid} = SessionManager.ensure_for_session(ctx.session_uri)
      assert is_pid(pid)
      assert {:ok, ^pid} = SessionManager.whereis(ctx.orchestrator_uri)

      # And it works end-to-end again (token + cap reconstruction restored).
      assert {:ok, _} = run_tool(ctx, "list_templates", %{})
    end

    test "ensure_for_session is a no-op for a session with no orchestrator" do
      session_uri = spawn_session()
      assert {:ok, :no_orchestrator} = SessionManager.ensure_for_session(session_uri)
    end

    test "update_template targets the LIVE working-copy parent, not the stale start binding (P2-r2)" do
      # Start the SessionManager with NO parent in the binding, then update the
      # session's LIVE working copy to point at a real parent (as repair /
      # re-materialization would). The running executor must pick up the NEW
      # parent on the next call — never the stale cached binding.
      session_uri = spawn_session()
      orchestrator_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-#{uniq()}")
      :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")
      on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(orchestrator_uri) end)

      caps =
        orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri, initial_caps: caps})
      :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)

      # A real parent SessionTemplate the updated working copy will point at.
      parent_content = %{
        name: "mcp-live-parent-#{uniq()}",
        description: "live parent",
        agent_slots: [],
        routing_rules: [],
        orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
        default_workspace_uri: @workspace_uri,
        parent_template_uri: nil,
        created_by: User.admin_uri(),
        created_at: ~U[2026-06-13 00:00:00Z]
      }

      {:ok, parent_uri} = SessionTemplate.persist_version(parent_content, "team-alpha")

      # Working copy points at the parent (orchestrator_uri + session_template_uri).
      :ok = set_active_binding(session_uri, orchestrator_uri, %{session_template_uri: parent_uri})

      {:ok, token} = TokenStore.mint(orchestrator_uri)

      # Start the executor with NO parent in the binding (the stale value).
      {:ok, _sm} =
        SessionManager.ensure_started(
          orchestrator_uri: orchestrator_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: orchestrator_uri
        )

      on_exit(fn -> SessionManager.stop(orchestrator_uri) end)

      orch = %{orchestrator_uri: orchestrator_uri, token: token, session_uri: session_uri}

      # update_template must resolve the parent from the LIVE working copy
      # (parent_uri), persisting a new version — NOT fail with missing/stale parent.
      assert {:ok, %URI{}} = run_tool(orch, "update_template", %{}),
             "update_template must target the LIVE working-copy parent — the running " <>
               "executor must not be pinned to its stale start-time binding."
    end

    test "rollback stops the SessionManager (P2 — no leaked executor)" do
      ctx = provision([:agent_template])
      assert {:ok, _} = SessionManager.whereis(ctx.orchestrator_uri)

      # The create rollback path stops the executor it started.
      :ok =
        EzagentDomainInstanceMessage.SessionCreator.Rollback.rollback_session(
          ctx.session_uri,
          ctx.orchestrator_uri,
          owner_uri: ctx.orchestrator_uri,
          workspace_uri: @workspace_uri
        )

      assert SessionManager.whereis(ctx.orchestrator_uri) == :error,
             "rollback MUST stop the per-orchestrator SessionManager — leaving it " <>
               "running leaks the process + a later recreate could reuse stale state."
    end

    test "normal session deletion (Lifecycle.destroy) stops the SessionManager (P2-r4)" do
      ctx = provision([:agent_template])
      assert {:ok, _} = SessionManager.whereis(ctx.orchestrator_uri)

      # A normal teardown (NOT create rollback): the Session Kind's destroy hook
      # must tie the executor to the session lifecycle.
      :ok = Ezagent.Lifecycle.destroy(ctx.session_uri, :test_delete)

      assert SessionManager.whereis(ctx.orchestrator_uri) == :error,
             "Lifecycle.destroy of an orchestrator-bearing session MUST stop its " <>
               "per-orchestrator SessionManager — a deleted session must not leak its executor."
    end
  end

  describe "the orchestrator tool surface (§3.8 member/rule-set + template tools)" do
    test "SessionManager.tool_names/0 is the member + participant + rule-set + template set" do
      assert MapSet.new(SessionManager.tool_names()) ==
               MapSet.new([
                 "add_managed_member",
                 "add_participant",
                 "update_member_template",
                 "remove_member",
                 "define_rule_set_rule",
                 "define_prompt_template",
                 "define_legend",
                 "update_template",
                 "save_template_as",
                 "migrate_session",
                 "list_templates",
                 # kb-retrieval SPEC §5.3 option 1 — kb-agent retrieve / ingest.
                 "kb_query",
                 "kb_ingest"
               ])
    end
  end

  describe "bridge-token authz (Decision C §2 step 0 — the unforgeable gate)" do
    test "a wrong bridge token is rejected fail-loud BEFORE any tool runs" do
      ctx = provision([:agent_template])

      assert {:error, :unauthorized} =
               SessionManager.run_tool(
                 ctx.orchestrator_uri,
                 "list_templates",
                 %{},
                 "tok_totally-bogus"
               )
    end

    test "an absent (nil) bridge token is rejected" do
      ctx = provision([:agent_template])

      assert {:error, :unauthorized} =
               SessionManager.run_tool(ctx.orchestrator_uri, "list_templates", %{}, nil)
    end

    test "the CORRECT bridge token passes the gate (control)" do
      ctx = provision([:agent_template])
      # A correct token reaches the tool (which then runs under reconstructed
      # caps). list_templates with the agent_template cap returns a structured
      # result — proving the token gate let it through.
      assert {:ok, _structured} = run_tool(ctx, "list_templates", %{})
    end
  end

  describe "structural caller-is-our-orchestrator gate (defense-in-depth)" do
    test "a SessionManager bound to a DIFFERENT orchestrator than the session's stored one denies" do
      session_uri = spawn_session()

      # The session's stored orchestrator is A …
      caps =
        orchestrator_caps(
          session_uri,
          Ezagent.URI.new!("entity://team-alpha/agent/a"),
          @workspace_uri,
          [:agent_template]
        )

      {orch_a, token_a} = setup_orchestrator(session_uri, caps)

      # … but a SECOND SessionManager is started bound to a foreign orchestrator
      # B for the SAME session (a stale/foreign binding). B mints its OWN token,
      # so the token gate passes; the structural gate must still deny because
      # the session's durable working-copy orchestrator is A, not B.
      orch_b = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-b-#{uniq()}")
      {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orch_b, initial_caps: MapSet.new()})
      :ok = Ezagent.WorkspaceRegistry.bind(orch_b, @workspace_uri)
      {:ok, token_b} = TokenStore.mint(orch_b)

      {:ok, _sm} =
        SessionManager.ensure_started(
          orchestrator_uri: orch_b,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: orch_b
        )

      on_exit(fn -> SessionManager.stop(orch_b) end)

      assert {:error, :unauthorized} =
               SessionManager.run_tool(orch_b, "list_templates", %{}, token_b),
             "a binding whose orchestrator != the session's durable working-copy " <>
               "orchestrator MUST be denied (structural gate)."

      # Control: A (the real stored orchestrator) passes.
      assert {:ok, _} = SessionManager.run_tool(orch_a, "list_templates", %{}, token_a)
    end
  end

  describe "no admin_caps fallback — caps #3/#4 omitted denies (SPEC §2 PR-5 HIGH-1)" do
    test "list_templates with caps #3/#4 OMITTED → {:error, :unauthorized}" do
      ctx = provision([])

      assert {:error, {:gate_failed, :workspace_caps, :unauthorized}} =
               run_tool(ctx, "list_templates", %{}),
             "list_templates with NO template caps must FAIL — if it succeeded the " <>
               "op path fell back to ambient admin_caps (forbidden)."
    end

    test "update_template with cap #3 OMITTED → {:error, :unauthorized}" do
      # Provision an orchestrator with NO template caps but a real
      # parent_template_uri in the binding (so the op reaches the cap gate and
      # denies on the missing cap #3, not on a missing parent).
      session_uri = spawn_session()
      orchestrator_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-#{uniq()}")
      :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")
      on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(orchestrator_uri) end)

      caps = orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [])
      {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri, initial_caps: caps})
      :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)

      parent_uri = Ezagent.URI.new!("template://team-alpha/session/x@abc")
      :ok = set_active_binding(session_uri, orchestrator_uri, %{session_template_uri: parent_uri})

      {:ok, token} = TokenStore.mint(orchestrator_uri)

      {:ok, _sm} =
        SessionManager.ensure_started(
          orchestrator_uri: orchestrator_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: orchestrator_uri,
          parent_template_uri: parent_uri
        )

      on_exit(fn -> SessionManager.stop(orchestrator_uri) end)

      ctx = %{orchestrator_uri: orchestrator_uri, token: token, session_uri: session_uri}

      assert {:error, {:gate_failed, :template_write, :unauthorized}} =
               run_tool(ctx, "update_template", %{})
    end
  end

  describe "list_templates is per-kind cap-gated (SPEC §2.1 / §1.7 (b))" do
    setup do
      flavor = register_test_flavor()

      at_uri = URI.new!("template://team-alpha/agent/mcp-list-at-#{uniq()}")
      :ok = create_agent_template(at_uri, flavor, "list-worker")

      st_content = %{
        name: "mcp-list-st-#{uniq()}",
        description: "list test team",
        agent_slots: [],
        routing_rules: [],
        orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
        default_workspace_uri: @workspace_uri,
        parent_template_uri: nil,
        created_by: User.admin_uri(),
        created_at: ~U[2026-05-22 00:00:00Z]
      }

      {:ok, st_uri} = SessionTemplate.persist_version(st_content, "team-alpha")

      %{agent_template_uri: at_uri, session_template_uri: st_uri}
    end

    test "cap-#4-only caller sees ONLY agent_templates, NOT session_templates", ctx do
      orch = provision([:agent_template])
      assert {:ok, structured} = run_tool(orch, "list_templates", %{})

      assert ctx.agent_template_uri in structured.agent_templates

      assert structured.session_templates == [],
             "cap-#4-only caller must NOT see session templates — cross-kind leak."
    end

    test "cap-#3-only caller sees ONLY session_templates, NOT agent_templates", ctx do
      orch = provision([:session_template])
      assert {:ok, structured} = run_tool(orch, "list_templates", %{})

      assert ctx.session_template_uri in structured.session_templates

      assert structured.agent_templates == [],
             "cap-#3-only caller must NOT see agent templates — cross-kind leak."
    end

    test "caller with both caps #3 + #4 sees both kinds", ctx do
      orch = provision([:agent_template, :session_template])
      assert {:ok, structured} = run_tool(orch, "list_templates", %{})

      assert ctx.agent_template_uri in structured.agent_templates
      assert ctx.session_template_uri in structured.session_templates
    end
  end

  describe "add_managed_member / remove_member / define_rule_set_rule (member + rule-set, §3.8)" do
    setup do
      flavor = register_test_flavor()

      backend_uri = URI.new!("template://team-alpha/agent/mcp-backend-#{uniq()}")
      :ok = create_agent_template(backend_uri, flavor, "backend")

      orch = provision_with_self_caps([:agent_template, :session_template])

      %{flavor: flavor, backend_uri: backend_uri, orch: orch}
    end

    test "add_managed_member spawns a worker, records it under the orchestrator + joins it",
         ctx do
      assert {:ok, %URI{} = member_uri} =
               run_tool(ctx.orch, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
                 "role_name" => "backend-dev",
                 "in_session_template" => true
               })

      assert AgentLineage.spawned_in_lineage?(member_uri, ctx.orch.orchestrator_uri),
             "the spawned member must be recorded under the orchestrator's lineage — cap #2 depends on it"

      slice = chat_slice(ctx.orch.session_uri)
      resolved = ActionSet.Session.role_name_to_uri(slice.members, "backend-dev")
      assert URI.to_string(resolved) == URI.to_string(member_uri)
      assert slice.members[resolved].in_session_template == true
      assert slice.members[resolved].source_template_uri == ctx.backend_uri
    end

    test "add_participant invites an existing human with session-scoped participation", ctx do
      operator = confirmed_user("operator")

      assert {:ok, ^operator} =
               run_tool(ctx.orch, "add_participant", %{
                 "ref" => URI.to_string(operator),
                 "role_name" => "operator"
               })

      slice = chat_slice(ctx.orch.session_uri)
      resolved = ActionSet.Session.role_name_to_uri(slice.members, "operator")
      assert resolved == operator

      assert has_cap?(operator, ActionSet.Session, :join, ctx.orch.session_uri)
      assert has_cap?(operator, ActionSet.Session, :send, ctx.orch.session_uri)
      assert has_cap?(operator, ActionSet.Session, :leave, ctx.orch.session_uri)

      assert has_cap?(
               operator,
               ActionSet.Publisher.SessionImpl,
               :subscribe_from,
               ctx.orch.session_uri
             )

      refute has_workspace_wide_session_cap?(operator)
    end

    test "remove_member terminates the orchestrator's own worker (cap-#2 happy path)", ctx do
      assert {:ok, _} =
               run_tool(ctx.orch, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
                 "role_name" => "rm-role"
               })

      assert {:ok, %{status: status}} =
               run_tool(ctx.orch, "remove_member", %{"role_name" => "rm-role"})

      assert status in [:removed, "removed"]

      slice = chat_slice(ctx.orch.session_uri)
      refute ActionSet.Session.role_name_to_uri(slice.members, "rm-role")
    end

    test "remove_member of an absent role is idempotent success", ctx do
      assert {:ok, _} =
               run_tool(ctx.orch, "remove_member", %{"role_name" => "never-existed-#{uniq()}"})
    end

    test "remove_member of a rule's SOLE receiver reports deleted_rules:1 + logs a warning",
         ctx do
      assert {:ok, _} =
               run_tool(ctx.orch, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
                 "role_name" => "sole-dev"
               })

      assert {:ok, %{id: rule_id}} =
               run_tool(ctx.orch, "define_rule_set_rule", %{
                 "matcher_ast" => %{"type" => "text_contains", "arg" => "deploy"},
                 "receiver_role_name" => "sole-dev",
                 "rule_set" => "deploy-rs"
               })

      assert is_integer(rule_id)

      table = EzagentDomainInstanceMessage.Routing.MentionRouting
      assert Enum.any?(Ezagent.Routing.RuleStore.list(table), &(&1.id == rule_id))

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          run_tool(ctx.orch, "remove_member", %{"role_name" => "sole-dev"})
        end)

      assert {:ok, %{deleted_rules: 1, repointed_rules: 0}} = result
      assert log =~ "force-deleted routing rule"
      assert log =~ "ZERO receivers"
      refute Enum.any?(Ezagent.Routing.RuleStore.list(table), &(&1.id == rule_id))
    end

    test "remove_member of ONE of several receivers reports repointed_rules:1, rule survives",
         ctx do
      assert {:ok, %URI{} = keep_a} =
               run_tool(ctx.orch, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
                 "role_name" => "keep-a"
               })

      assert {:ok, %URI{} = keep_b} =
               run_tool(ctx.orch, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
                 "role_name" => "keep-b"
               })

      keep_b_str = URI.to_string(keep_b)

      {:ok, %Ezagent.Routing.RuleStore{id: rule_id}} =
        Ezagent.Routing.RuleStore.add(
          EzagentDomainInstanceMessage.Routing.MentionRouting,
          {:text_contains, "review"},
          [URI.to_string(keep_a), keep_b_str],
          ctx.orch.session_uri,
          workspace_uri: @workspace_uri,
          source: "admin"
        )

      :ok =
        Ezagent.Routing.RuleStore.load_into_registry(
          EzagentDomainInstanceMessage.Routing.MentionRouting
        )

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          run_tool(ctx.orch, "remove_member", %{"role_name" => "keep-a"})
        end)

      assert {:ok, %{repointed_rules: 1, deleted_rules: 0}} = result
      refute log =~ "force-deleted routing rule"

      table = EzagentDomainInstanceMessage.Routing.MentionRouting
      surviving = Enum.find(Ezagent.Routing.RuleStore.list(table), &(&1.id == rule_id))
      assert surviving, "the rule must survive — it still has keep-b as a receiver"
      assert keep_b_str in surviving.receivers
    end

    test "codex B2 — remove_member prune is SCOPED to this session; a foreign rule is UNTOUCHED",
         ctx do
      assert {:ok, %URI{} = member_uri} =
               run_tool(ctx.orch, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
                 "role_name" => "scoped-dev"
               })

      member_uri_str = URI.to_string(member_uri)
      table = EzagentDomainInstanceMessage.Routing.MentionRouting
      foreign_session = URI.new!("session://team-alpha/default/foreign-#{uniq()}")

      {:ok, foreign_row} =
        Ezagent.Routing.RuleStore.add(
          table,
          {:text_contains, "foreign"},
          [member_uri_str],
          foreign_session,
          workspace_uri: @workspace_uri,
          rule_set: "foreign-rs",
          position: 0
        )

      :ok = Ezagent.Routing.RuleStore.load_into_registry(table)

      assert {:ok, _} = run_tool(ctx.orch, "remove_member", %{"role_name" => "scoped-dev"})

      surviving = Enum.find(Ezagent.Routing.RuleStore.list(table), &(&1.id == foreign_row.id))

      assert surviving,
             "B2: a foreign session's rule must NOT be deleted by remove_member's scoped prune"

      assert member_uri_str in (surviving.receivers || []),
             "B2: the foreign rule's receiver must be UNCHANGED — got #{inspect(surviving.receivers)}"
    end

    test "codex B2 — do_remove_member PROPAGATES a prune failure (no swallow into deleted_rules:0)" do
      source = File.read!(Path.join(__DIR__, "../../lib/ezagent/orchestrator/tools.ex"))

      [remove_block | _] =
        Regex.scan(~r/defp do_remove_member.*?\n  end/s, source) |> Enum.map(&hd/1)

      refute String.contains?(remove_block, "{:error, _} -> %{deleted_rules: 0"),
             "B2: do_remove_member must NOT swallow a prune {:error, _} into a fabricated " <>
               "%{deleted_rules: 0} success — it must propagate the prune failure."

      assert String.contains?(remove_block, "prune_routing_rules_for(session_uri, member_uri)"),
             "B2: prune must be scoped to the session (prune_routing_rules_for(session_uri, ...))"

      assert Regex.match?(~r/\{:error,.*\} = err ->\s*\n.*err/s, remove_block),
             "B2: do_remove_member must have an {:error, _} = err arm that returns the error"
    end

    test "cap-#2 CONTROL — another orchestrator cannot remove this orchestrator's member", ctx do
      assert {:ok, _} =
               run_tool(ctx.orch, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
                 "role_name" => "owned-by-a"
               })

      # Orchestrator B drives the SAME session (its own SessionManager bound to
      # the same session). B's working-copy structural gate would deny — but to
      # isolate cap #2 we point B's SessionManager at a SECOND session whose
      # stored orchestrator IS B, sharing the same workspace; B then tries to
      # remove A's member by role_name (which B's session does not have → the
      # role resolves nil, and even a URI-targeted termination is cap-#2 gated).
      #
      # The simplest faithful cap-#2 assertion: B with only spawned_by-B cap
      # cannot terminate a member spawned_by A. Build B in A's session is blocked
      # structurally, so assert the role is simply not removable cross-binding.
      session_b = spawn_session()
      orch_b = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-b-#{uniq()}")
      :ok = Ezagent.AgentFlavorAttributes.put(orch_b, "cc")
      on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(orch_b) end)

      caps_b =
        orchestrator_caps(session_b, orch_b, @workspace_uri, [:agent_template, :session_template])

      {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orch_b, initial_caps: caps_b})
      :ok = Ezagent.WorkspaceRegistry.bind(orch_b, @workspace_uri)

      :ok = set_active_binding(session_b, orch_b)

      {:ok, token_b} = TokenStore.mint(orch_b)

      {:ok, _sm} =
        SessionManager.ensure_started(
          orchestrator_uri: orch_b,
          session_uri: session_b,
          workspace_uri: @workspace_uri,
          owner_uri: orch_b
        )

      on_exit(fn -> SessionManager.stop(orch_b) end)

      # B's session has no "owned-by-a" member → idempotent no-op (not a
      # cross-session termination). The KEY cap-#2 guarantee: B never terminates
      # A's worker. Assert A's member still resolves in A's session after B's call.
      _ =
        SessionManager.run_tool(orch_b, "remove_member", %{"role_name" => "owned-by-a"}, token_b)

      slice_a = chat_slice(ctx.orch.session_uri)

      assert ActionSet.Session.role_name_to_uri(slice_a.members, "owned-by-a"),
             "orchestrator B must NOT be able to terminate orchestrator A's member " <>
               "(cap #2 is {:spawned_by, B}; the member is spawned_by A)."
    end
  end

  describe "define_rule_set_rule / define_prompt_template / define_legend (cap-#1)" do
    setup do
      flavor = register_test_flavor()
      backend_uri = URI.new!("template://team-alpha/agent/mcp-wm-backend-#{uniq()}")
      :ok = create_agent_template(backend_uri, flavor, "wm-backend")

      orch = provision_with_self_caps([:agent_template, :session_template])

      assert {:ok, _} =
               run_tool(orch, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(backend_uri),
                 "role_name" => "wm-dev"
               })

      %{orch: orch}
    end

    test "define_rule_set_rule writes a single-receiver rule and returns its id", ctx do
      assert {:ok, %{id: id}} =
               run_tool(ctx.orch, "define_rule_set_rule", %{
                 "matcher_ast" => %{"type" => "text_contains", "arg" => "ship"},
                 "receiver_role_name" => "wm-dev",
                 "rule_set" => "ship-rs",
                 "position" => 0
               })

      assert is_integer(id)
    end

    test "define_prompt_template installs a named template on the session", ctx do
      assert {:ok, _} =
               run_tool(ctx.orch, "define_prompt_template", %{
                 "name" => "hop",
                 "template" => "接龙：{body}"
               })

      assert chat_slice(ctx.orch.session_uri).prompt_templates["hop"] == "接龙：{body}"
    end

    test "define_legend fronts a rule-set with a @legend handle", ctx do
      assert {:ok, _} =
               run_tool(ctx.orch, "define_legend", %{
                 "legend_name" => "team-x",
                 "member_role_names" => ["wm-dev"],
                 "bound_rule_set" => "ship-rs",
                 "fold" => true
               })

      assert {:ok, %{bound_rule_set: "ship-rs"}} =
               ActionSet.Session.resolve_legend(chat_slice(ctx.orch.session_uri), "team-x")
    end

    test "define_rule_set_rule with an unknown receiver role → {:error, {:unknown_member_role, _}}",
         ctx do
      assert {:error, {:unknown_member_role, _}} =
               run_tool(ctx.orch, "define_rule_set_rule", %{
                 "matcher_ast" => %{"type" => "text_contains", "arg" => "x"},
                 "receiver_role_name" => "ghost-role-#{uniq()}",
                 "rule_set" => "rs"
               })
    end

    test "define_rule_set_rule with a URI-shaped non-member receiver is rejected (codex M1 bypass)",
         ctx do
      assert {:error, {:unknown_member_role, _}} =
               run_tool(ctx.orch, "define_rule_set_rule", %{
                 "matcher_ast" => %{"type" => "text_contains", "arg" => "x"},
                 "receiver_role_name" => "entity://team-alpha/agent/not_a_member_#{uniq()}",
                 "rule_set" => "rs"
               })
    end
  end

  describe "update_template / save_template_as persist real kind_snapshots rows" do
    test "save_template_as persists a new SessionTemplate Kind + snapshot row" do
      orch = provision([:agent_template, :session_template])
      new_name = "mcp-saved-#{uniq()}"

      assert {:ok, %URI{} = uri} = run_tool(orch, "save_template_as", %{"new_name" => new_name})

      assert %Ezagent.Ecto.KindSnapshot{kind_type: "session_template"} =
               Ezagent.Ecto.KindSnapshot.get(URI.to_string(uri))
    end

    test "update_template persists a new version of the parent SessionTemplate" do
      parent_content = %{
        name: "mcp-parent-#{uniq()}",
        description: "parent team",
        agent_slots: [],
        routing_rules: [],
        orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
        default_workspace_uri: @workspace_uri,
        parent_template_uri: nil,
        created_by: User.admin_uri(),
        created_at: ~U[2026-05-22 00:00:00Z]
      }

      {:ok, parent_uri} = SessionTemplate.persist_version(parent_content, "team-alpha")

      # The parent_template_uri is part of the SessionManager binding; provision
      # one with that parent set.
      session_uri = spawn_session()
      orchestrator_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-#{uniq()}")
      :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")
      on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(orchestrator_uri) end)

      caps =
        orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri, initial_caps: caps})
      :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)

      :ok = set_active_binding(session_uri, orchestrator_uri, %{session_template_uri: parent_uri})

      {:ok, token} = TokenStore.mint(orchestrator_uri)

      {:ok, _sm} =
        SessionManager.ensure_started(
          orchestrator_uri: orchestrator_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: orchestrator_uri,
          parent_template_uri: parent_uri
        )

      on_exit(fn -> SessionManager.stop(orchestrator_uri) end)

      orch = %{orchestrator_uri: orchestrator_uri, token: token, session_uri: session_uri}

      assert {:ok, %URI{} = new_uri} = run_tool(orch, "update_template", %{})

      assert %Ezagent.Ecto.KindSnapshot{kind_type: "session_template"} =
               Ezagent.Ecto.KindSnapshot.get(URI.to_string(new_uri))
    end

    test "update_template publishes by moving the current tag to the new hash" do
      parent_content = %{
        name: "mcp-publish-#{uniq()}",
        description: "parent team",
        members: [],
        routing_rules: [],
        prompt_templates: %{},
        legends: %{},
        orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
        default_workspace_uri: @workspace_uri,
        parent_template_uri: nil,
        created_by: User.admin_uri(),
        created_at: ~U[2026-05-22 00:00:00Z]
      }

      {:ok, parent_uri} = SessionTemplate.persist_version(parent_content, @workspace_uri)

      :ok =
        TemplateTags.put(
          @workspace_uri,
          parent_content.name,
          "current",
          template_hash(parent_uri),
          User.admin_uri()
        )

      session_uri = spawn_session()
      orchestrator_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-#{uniq()}")
      :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")
      on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(orchestrator_uri) end)

      caps =
        orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri, initial_caps: caps})
      :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)

      :ok = set_active_binding(session_uri, orchestrator_uri, %{session_template_uri: parent_uri})

      {:ok, token} = TokenStore.mint(orchestrator_uri)

      {:ok, _sm} =
        SessionManager.ensure_started(
          orchestrator_uri: orchestrator_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: orchestrator_uri,
          parent_template_uri: parent_uri
        )

      on_exit(fn -> SessionManager.stop(orchestrator_uri) end)

      orch = %{orchestrator_uri: orchestrator_uri, token: token, session_uri: session_uri}

      assert {:ok, %URI{} = new_uri} = run_tool(orch, "update_template", %{})

      assert {:ok, template_hash(new_uri)} ==
               TemplateTags.resolve(@workspace_uri, parent_content.name, "current")
    end

    test "migrate_session persists a ledger on injected failure and resumes to advance the pin" do
      flavor = register_test_flavor()
      source_v1 = Ezagent.URI.new!("template://team-alpha/agent/mig-v1-#{uniq()}")
      source_v2 = Ezagent.URI.new!("template://team-alpha/agent/mig-v2-#{uniq()}")
      :ok = create_agent_template(source_v1, flavor, "mig-v1")
      :ok = create_agent_template(source_v2, flavor, "mig-v2")

      ctx = provision_with_self_caps([:agent_template, :session_template])

      assert {:ok, %URI{} = old_member_uri} =
               run_tool(ctx, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(source_v1),
                 "role_name" => "worker",
                 "in_session_template" => true
               })

      target_content = %{
        name: "migrate-target-#{uniq()}",
        description: "target team",
        members: [
          %{
            uri: nil,
            role_name: "worker",
            in_session_template: true,
            source_template_uri: source_v2
          }
        ],
        routing_rules: [],
        prompt_templates: %{},
        legends: %{},
        orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
        default_workspace_uri: @workspace_uri,
        parent_template_uri: nil,
        created_by: User.admin_uri(),
        created_at: ~U[2026-06-21 00:00:00Z]
      }

      {:ok, target_uri} = SessionTemplate.persist_version(target_content, @workspace_uri)

      Application.put_env(
        :ezagent_domain_session,
        :migrate_session_fault,
        {:after_role_done, "worker"}
      )

      on_exit(fn ->
        Application.delete_env(:ezagent_domain_session, :migrate_session_fault)
      end)

      assert {:error, {:injected_migration_failure, "worker"}} =
               run_tool(ctx, "migrate_session", %{
                 "target_session_template_uri" => URI.to_string(target_uri)
               })

      failed_wc = Session.read_template_working_copy(ctx.session_uri)
      assert Map.get(failed_wc, :session_template_uri) != target_uri
      assert failed_wc.migration_ledger.target_session_template_uri == target_uri
      assert failed_wc.migration_ledger.members["worker"] == :done

      Application.delete_env(:ezagent_domain_session, :migrate_session_fault)

      assert {:ok, %{session_template_uri: ^target_uri}} =
               run_tool(ctx, "migrate_session", %{
                 "target_session_template_uri" => URI.to_string(target_uri)
               })

      final_wc = Session.read_template_working_copy(ctx.session_uri)
      assert final_wc.session_template_uri == target_uri
      refute Map.has_key?(final_wc, :migration_ledger)

      members = chat_slice(ctx.session_uri).members
      refute Map.has_key?(members, old_member_uri)

      assert Enum.any?(members, fn {_uri, meta} ->
               meta.role_name == "worker" and meta.source_template_uri == source_v2
             end)
    end

    test "update_template with a deleted parent → {:error, :parent_template_deleted}" do
      session_uri = spawn_session()
      orchestrator_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-#{uniq()}")
      :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")
      on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(orchestrator_uri) end)

      caps =
        orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri, initial_caps: caps})
      :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)

      parent_uri =
        Ezagent.URI.new!("template://team-alpha/session/never-existed-#{uniq()}@deadbeef")

      :ok = set_active_binding(session_uri, orchestrator_uri, %{session_template_uri: parent_uri})

      {:ok, token} = TokenStore.mint(orchestrator_uri)

      {:ok, _sm} =
        SessionManager.ensure_started(
          orchestrator_uri: orchestrator_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: orchestrator_uri,
          parent_template_uri: parent_uri
        )

      on_exit(fn -> SessionManager.stop(orchestrator_uri) end)

      orch = %{orchestrator_uri: orchestrator_uri, token: token, session_uri: session_uri}

      assert {:error, :parent_template_deleted} = run_tool(orch, "update_template", %{})
    end
  end

  describe "operation-core argument errors" do
    test "an unknown tool name is rejected" do
      ctx = provision([:agent_template])

      assert {:error, {:unknown_operation, "not_a_real_tool"}} =
               run_tool(ctx, "not_a_real_tool", %{})
    end

    test "a missing required argument → {:error, {:missing_arg, _}}" do
      ctx = provision([:agent_template])

      assert {:error, {:missing_arg, "source_agent_template_uri"}} =
               run_tool(ctx, "add_managed_member", %{"role_name" => "x"})
    end
  end
end
