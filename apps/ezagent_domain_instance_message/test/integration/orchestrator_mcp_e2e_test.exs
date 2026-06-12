defmodule EzagentDomainInstanceMessage.Integration.OrchestratorMcpE2eTest do
  @moduledoc """
  Phase 7 completion PR-5 (SPEC §2 "PR-5") — the deterministic
  fake-LLM / fake-MCP end-to-end test for the privileged orchestrator
  MCP surface.

  This drives all 7 `Ezagent.Orchestrator.Tools` THROUGH the orchestrator
  MCP server (`Ezagent.Orchestrator.McpServer`) — exactly as a live
  `claude` orchestrator's MCP client would: `handle_tool_call/3` with a
  JSON-shaped argument map. There is NO mock dispatch — every tool runs
  the real `Ezagent.Invocation.dispatch/1` path with the orchestrator's
  bound caps as `ctx`.

  ## The "fake LLM" + "fake MCP"

  The fake LLM is the test body itself — it issues a deterministic
  sequence of `McpServer.handle_tool_call/3` calls (the same calls a
  real claude would make from `tools/call`). The fake MCP transport is
  `McpServer.handle_tool_call/3` directly — the ESR-side handler the
  Python stdio bridge would forward to. Both are deterministic: no
  network, no real `claude`, no timers.

  ## What it proves (SPEC §2 PR-5 test list)

  1. **No-`admin_caps`-fallback denial** — `list_templates` with caps
     #3/#4 OMITTED returns a structured `:unauthorized` MCP error. If
     the tool path fell back to ambient `admin_caps` this would
     succeed; it must NOT.
  2. **cap-#2 happy path** — `remove_agent_slot` / `update_agent_template`
     on a worker THIS orchestrator spawned via the delegated path
     SUCCEED (proving the §1.6a wrapper recorded lineage under the
     orchestrator); the control against ANOTHER orchestrator's worker
     DENIES.
  3. **MEDIUM-5 per-kind list** — a cap-#3-only caller sees
     `session_templates` but NOT `agent_templates`; a cap-#4-only
     caller sees the inverse; neither leaks the other kind's URIs.
  4. **per-tool effects** — each of the 7 tools produces its intended
     effect (a worker spawned, a slot removed, a routing rule written,
     a template version persisted, the catalog listed).
  5. **agent-slot maintenance** — the agent-slot tools keep
     `template_working_copy.agent_slots` consistent.

  The human agent-browser demo is supplemental release evidence — NOT
  this CI gate.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentFlavorRegistry, AgentLineage, Behavior, Capability, KindRegistry}
  alias Ezagent.Entity.{Agent, Session, SessionTemplate, User}
  alias Ezagent.Orchestrator.McpServer

  # --- a no-PTY test Template Class --------------------------------------

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
    # codex round-6 HIGH-1 — return the 3-element `{:ok, uris, %{fresh?:
    # _}}` form, deriving `fresh?` from the ATOMIC spawn result
    # (`SpawnRegistry.spawn_detailed/1`). A Template Class that spawns
    # MUST report the real freshness signal — `update_agent_template`'s
    # swap rejects a non-fresh (adopted) candidate.
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

  # --- helpers -----------------------------------------------------------

  defp uniq, do: System.unique_integer([:positive])

  @workspace_uri URI.new!("workspace://team-alpha")

  # Register a unique synthetic flavor: the worker Kind is the plain
  # `Ezagent.Entity.Agent` (no PTY, no claude). The flavor name is the
  # `<flavor>` prefix the instance URI carries.
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
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  # Spawn an AgentTemplate Kind at `uri` + populate its `:template`
  # slice via the dispatch `:write` path.
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

  # A `Behavior.Template` cap, workspace-bounded.
  defp template_cap(kind, workspace_uri) do
    %Capability{
      kind: kind,
      behavior: Behavior.Template,
      instance: {:within_workspace, workspace_uri},
      workspace_uri: workspace_uri,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  # The four delegated caps the Generator grants an orchestrator (§1.4):
  # #1 within_session, #2 spawned_by, #3 session_template,
  # #4 agent_template. `kinds` selects which template caps are present
  # — the no-fallback denial test omits #3/#4 by passing `[]`.
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

  # Spawn a fresh Session Kind + bind its workspace.
  defp spawn_session do
    session_uri = Ezagent.URI.session("team-alpha", "generic", "mcp-e2e-#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    session_uri
  end

  # Spawn an orchestrator Agent Kind (the cc-flavored agent the
  # Generator would have spawned).
  defp spawn_orchestrator do
    orchestrator_uri =
      Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-#{uniq()}")

    :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")

    on_exit(fn ->
      Ezagent.AgentFlavorAttributes.delete(orchestrator_uri)
    end)

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)
    orchestrator_uri
  end

  # Build an `%McpServer{}` bound to (session, orchestrator, ws, caps).
  defp mcp_server(session_uri, orchestrator_uri, caps, opts \\ []) do
    {:ok, ctx} =
      McpServer.new(
        Keyword.merge(
          [
            orchestrator_uri: orchestrator_uri,
            session_uri: session_uri,
            workspace_uri: @workspace_uri,
            caps: caps
          ],
          opts
        )
      )

    ctx
  end

  # Read the live Session Kind's :chat persistent slice.
  defp chat_slice(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{chat: %{state: slice}}} = :sys.get_state(pid)
    slice
  end

  # --- the MCP-server tool schema surface --------------------------------

  describe "the orchestrator MCP server exposes the §3.8 member/rule-set + template tools" do
    test "tool_schemas/0 has one valid JSON schema per declared tool" do
      schemas = McpServer.tool_schemas()

      names = Enum.map(schemas, & &1["name"]) |> MapSet.new()

      # §3.8 retired the slot tools; the surface is member + rule-set
      # oriented plus the three retained template tools.
      assert names ==
               MapSet.new(~w(add_managed_member update_member_template remove_member
                             define_rule_set_rule define_prompt_template define_legend
                             update_template save_template_as list_templates))

      for schema <- schemas do
        assert is_binary(schema["description"])
        assert schema["inputSchema"]["type"] == "object"
        assert is_map(schema["inputSchema"]["properties"])
        assert is_list(schema["inputSchema"]["required"])
      end
    end

    test "the MCP tool names match Tools.tool_names/0" do
      assert MapSet.new(McpServer.tool_names()) ==
               MapSet.new(Enum.map(Ezagent.Orchestrator.Tools.tool_names(), &Atom.to_string/1))
    end
  end

  # --- THE no-admin_caps-fallback denial test ----------------------------

  describe "no admin_caps fallback — caps #3/#4 omitted denies (SPEC §2 PR-5 HIGH-1)" do
    test "list_templates with caps #3/#4 OMITTED → structured :unauthorized MCP error" do
      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()

      # The orchestrator holds ONLY caps #1/#2 — NO template caps.
      caps = orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [])
      mcp = mcp_server(session_uri, orchestrator_uri, caps)

      result = McpServer.handle_tool_call(mcp, "list_templates", %{})

      assert result["isError"] == true,
             "list_templates with NO template caps must FAIL — if it succeeded the " <>
               "tool path fell back to ambient admin_caps (forbidden)."

      assert result["error"]["code"] == "unauthorized"
    end

    test "update_template with cap #3 OMITTED → structured :unauthorized MCP error" do
      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()

      caps = orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [])

      mcp =
        mcp_server(session_uri, orchestrator_uri, caps,
          parent_template_uri: Ezagent.URI.new!("template://team-alpha/session/x@abc")
        )

      result = McpServer.handle_tool_call(mcp, "update_template", %{})

      assert result["isError"] == true
      assert result["error"]["code"] == "unauthorized"
    end
  end

  # --- the per-kind cap-gated list (MEDIUM-5) -----------------------------

  describe "list_templates is per-kind cap-gated (SPEC §2.1 / §1.7 (b))" do
    setup do
      flavor = register_test_flavor()

      # One AgentTemplate + one SessionTemplate in the workspace.
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

      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()

      %{
        session_uri: session_uri,
        orchestrator_uri: orchestrator_uri,
        agent_template_uri: at_uri,
        session_template_uri: st_uri
      }
    end

    test "cap-#4-only caller sees ONLY agent_templates, NOT session_templates", ctx do
      caps =
        orchestrator_caps(ctx.session_uri, ctx.orchestrator_uri, @workspace_uri, [:agent_template])

      mcp = mcp_server(ctx.session_uri, ctx.orchestrator_uri, caps)
      result = McpServer.handle_tool_call(mcp, "list_templates", %{})

      refute result["isError"]
      structured = result["structuredContent"]

      assert URI.to_string(ctx.agent_template_uri) in structured["agent_templates"]

      assert structured["session_templates"] == [],
             "cap-#4-only caller must NOT see session templates — cross-kind leak."
    end

    test "cap-#3-only caller sees ONLY session_templates, NOT agent_templates", ctx do
      caps =
        orchestrator_caps(ctx.session_uri, ctx.orchestrator_uri, @workspace_uri, [
          :session_template
        ])

      mcp = mcp_server(ctx.session_uri, ctx.orchestrator_uri, caps)
      result = McpServer.handle_tool_call(mcp, "list_templates", %{})

      refute result["isError"]
      structured = result["structuredContent"]

      assert URI.to_string(ctx.session_template_uri) in structured["session_templates"]

      assert structured["agent_templates"] == [],
             "cap-#3-only caller must NOT see agent templates — cross-kind leak."
    end

    test "caller with both caps #3 + #4 sees both kinds", ctx do
      caps =
        orchestrator_caps(ctx.session_uri, ctx.orchestrator_uri, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      mcp = mcp_server(ctx.session_uri, ctx.orchestrator_uri, caps)
      result = McpServer.handle_tool_call(mcp, "list_templates", %{})

      refute result["isError"]
      structured = result["structuredContent"]

      assert URI.to_string(ctx.agent_template_uri) in structured["agent_templates"]
      assert URI.to_string(ctx.session_template_uri) in structured["session_templates"]
    end
  end

  # --- per-tool effect + cap-#2 happy path -------------------------------

  describe "add_managed_member / remove_member / define_rule_set_rule (member + rule-set, §3.8)" do
    setup do
      flavor = register_test_flavor()

      backend_uri = URI.new!("template://team-alpha/agent/mcp-backend-#{uniq()}")
      :ok = create_agent_template(backend_uri, flavor, "backend")

      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()

      caps =
        orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      mcp = mcp_server(session_uri, orchestrator_uri, caps)

      %{
        flavor: flavor,
        session_uri: session_uri,
        orchestrator_uri: orchestrator_uri,
        backend_uri: backend_uri,
        mcp: mcp
      }
    end

    test "add_managed_member spawns a worker, records it under the orchestrator + joins it as a member",
         ctx do
      result =
        McpServer.handle_tool_call(ctx.mcp, "add_managed_member", %{
          "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
          "role_name" => "backend-dev",
          "in_session_template" => true
        })

      refute result["isError"], "add_managed_member failed: #{inspect(result)}"
      member_uri_str = result["structuredContent"]

      # The worker is in AgentLineage UNDER THE ORCHESTRATOR — what makes
      # cap #2 resolve for remove_member.
      assert AgentLineage.spawned_in_lineage?(
               Ezagent.URI.new!(member_uri_str),
               ctx.orchestrator_uri
             ),
             "the spawned member must be recorded under the orchestrator's lineage — cap #2 depends on it"

      # It joined the session as a member carrying its role_name + facets.
      slice = chat_slice(ctx.session_uri)
      member_uri = Behavior.Chat.role_name_to_uri(slice.members, "backend-dev")
      assert URI.to_string(member_uri) == member_uri_str
      assert slice.members[member_uri].in_session_template == true
      assert slice.members[member_uri].source_template_uri == ctx.backend_uri
    end

    test "remove_member terminates the orchestrator's own worker (cap-#2 happy path)", ctx do
      add =
        McpServer.handle_tool_call(ctx.mcp, "add_managed_member", %{
          "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
          "role_name" => "rm-role"
        })

      refute add["isError"]

      result = McpServer.handle_tool_call(ctx.mcp, "remove_member", %{"role_name" => "rm-role"})

      refute result["isError"],
             "remove_member on the orchestrator's OWN worker must SUCCEED — cap #2 " <>
               "({:spawned_by, orchestrator}) authorizes it. Got: #{inspect(result)}"

      assert result["structuredContent"]["status"] in [:removed, "removed"]

      # The member is gone from the session.
      slice = chat_slice(ctx.session_uri)
      refute Behavior.Chat.role_name_to_uri(slice.members, "rm-role")
    end

    test "remove_member of an absent role is idempotent success", ctx do
      result =
        McpServer.handle_tool_call(ctx.mcp, "remove_member", %{
          "role_name" => "never-existed-#{uniq()}"
        })

      refute result["isError"]
    end

    test "remove_member of a rule's SOLE receiver reports deleted_rules:1 + logs a warning",
         ctx do
      add =
        McpServer.handle_tool_call(ctx.mcp, "add_managed_member", %{
          "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
          "role_name" => "sole-dev"
        })

      refute add["isError"]

      wm =
        McpServer.handle_tool_call(ctx.mcp, "define_rule_set_rule", %{
          "matcher_ast" => %{"type" => "text_contains", "arg" => "deploy"},
          "receiver_role_name" => "sole-dev",
          "rule_set" => "deploy-rs"
        })

      refute wm["isError"], "define_rule_set_rule failed: #{inspect(wm)}"
      rule_id = wm["structuredContent"]["id"]
      assert is_integer(rule_id)

      table = EzagentDomainInstanceMessage.Routing.MentionRouting
      assert Enum.any?(Ezagent.Routing.RuleStore.list(table), &(&1.id == rule_id))

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          McpServer.handle_tool_call(ctx.mcp, "remove_member", %{"role_name" => "sole-dev"})
        end)

      refute result["isError"], "remove_member failed: #{inspect(result)}"

      assert result["structuredContent"]["deleted_rules"] == 1,
             "removing the sole receiver must report deleted_rules:1 — got #{inspect(result["structuredContent"])}"

      assert result["structuredContent"]["repointed_rules"] == 0
      assert log =~ "force-deleted routing rule"
      assert log =~ "ZERO receivers"
      refute Enum.any?(Ezagent.Routing.RuleStore.list(table), &(&1.id == rule_id))
    end

    test "remove_member of ONE of several receivers reports repointed_rules:1, rule survives",
         ctx do
      keep_a =
        McpServer.handle_tool_call(ctx.mcp, "add_managed_member", %{
          "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
          "role_name" => "keep-a"
        })

      keep_b =
        McpServer.handle_tool_call(ctx.mcp, "add_managed_member", %{
          "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
          "role_name" => "keep-b"
        })

      refute keep_a["isError"]
      refute keep_b["isError"]
      keep_b_worker = keep_b["structuredContent"]

      # A standalone (no rule_set) multi-receiver rule naming both members.
      # define_rule_set_rule is single-receiver; for the multi-receiver
      # prune-vs-repoint test we write the rule directly via the same
      # routing.add_rule dispatch the tool uses.
      {:ok, %Ezagent.Routing.RuleStore{id: rule_id}} =
        Ezagent.Routing.RuleStore.add(
          EzagentDomainInstanceMessage.Routing.MentionRouting,
          {:text_contains, "review"},
          [keep_a["structuredContent"], keep_b_worker],
          ctx.session_uri,
          workspace_uri: @workspace_uri,
          source: "admin"
        )

      :ok =
        Ezagent.Routing.RuleStore.load_into_registry(
          EzagentDomainInstanceMessage.Routing.MentionRouting
        )

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          McpServer.handle_tool_call(ctx.mcp, "remove_member", %{"role_name" => "keep-a"})
        end)

      refute result["isError"], "remove_member failed: #{inspect(result)}"

      assert result["structuredContent"]["repointed_rules"] == 1,
             "removing one of several receivers must report repointed_rules:1 — got #{inspect(result["structuredContent"])}"

      assert result["structuredContent"]["deleted_rules"] == 0
      refute log =~ "force-deleted routing rule"

      table = EzagentDomainInstanceMessage.Routing.MentionRouting
      surviving = Enum.find(Ezagent.Routing.RuleStore.list(table), &(&1.id == rule_id))
      assert surviving, "the rule must survive — it still has keep-b as a receiver"
      assert keep_b_worker in surviving.receivers
    end

    test "codex B2 — remove_member prune is SCOPED to this session; a foreign session's rule naming the same member is UNTOUCHED",
         ctx do
      add =
        McpServer.handle_tool_call(ctx.mcp, "add_managed_member", %{
          "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
          "role_name" => "scoped-dev"
        })

      refute add["isError"]
      member_uri_str = add["structuredContent"]

      table = EzagentDomainInstanceMessage.Routing.MentionRouting

      # A FOREIGN session's rule that ALSO names this member URI as a
      # receiver, created_by a DIFFERENT session. Pre-fix the unscoped prune
      # (filter = "member string in receivers", no created_by check) would
      # delete/mutate it out from under that other session.
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

      result =
        McpServer.handle_tool_call(ctx.mcp, "remove_member", %{"role_name" => "scoped-dev"})

      refute result["isError"], "remove_member failed: #{inspect(result)}"

      # The foreign session's rule SURVIVES with its receiver unchanged —
      # only THIS session's rules (created_by == ctx.session_uri) are prunable.
      surviving = Enum.find(Ezagent.Routing.RuleStore.list(table), &(&1.id == foreign_row.id))

      assert surviving,
             "B2: a foreign session's rule must NOT be deleted by remove_member's scoped prune"

      assert member_uri_str in (surviving.receivers || []),
             "B2: the foreign rule's receiver must be UNCHANGED — got #{inspect(surviving.receivers)}"
    end

    test "codex B2 — remove_member PROPAGATES a prune failure (no swallow into deleted_rules:0)" do
      # No mocking library is available in this umbrella, so assert the
      # propagation STRUCTURALLY over the source (mirrors the existing
      # `save_template_as does NOT call check_parent_alive` design-lock test):
      # the prune-result handling in `do_remove_member` must NOT convert an
      # `{:error, _}` prune into a fabricated `%{deleted_rules: 0}` success.
      source = File.read!(Path.join(__DIR__, "../../lib/ezagent/orchestrator/tools.ex"))

      [remove_block | _] =
        Regex.scan(~r/defp do_remove_member.*?\n  end/s, source) |> Enum.map(&hd/1)

      refute String.contains?(remove_block, "{:error, _} -> %{deleted_rules: 0"),
             "B2: do_remove_member must NOT swallow a prune {:error, _} into a fabricated " <>
               "%{deleted_rules: 0} success — it must propagate the prune failure."

      # And the prune call is in an explicit case that propagates the error arm.
      assert String.contains?(remove_block, "prune_routing_rules_for(session_uri, member_uri)"),
             "B2: prune must be scoped to the session (prune_routing_rules_for(session_uri, ...))"

      assert Regex.match?(~r/\{:error,.*\} = err ->\s*\n.*err/s, remove_block),
             "B2: do_remove_member must have an {:error, _} = err arm that returns the error"
    end

    test "cap-#2 CONTROL — another orchestrator cannot remove this orchestrator's member", ctx do
      add =
        McpServer.handle_tool_call(ctx.mcp, "add_managed_member", %{
          "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
          "role_name" => "owned-by-a"
        })

      refute add["isError"]

      orchestrator_b = spawn_orchestrator()

      caps_b =
        orchestrator_caps(ctx.session_uri, orchestrator_b, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      mcp_b = mcp_server(ctx.session_uri, orchestrator_b, caps_b)

      result = McpServer.handle_tool_call(mcp_b, "remove_member", %{"role_name" => "owned-by-a"})

      assert result["isError"] == true,
             "orchestrator B must NOT be able to terminate orchestrator A's member — " <>
               "cap #2 is {:spawned_by, B}, the member is spawned_by A. Got: #{inspect(result)}"

      assert result["error"]["code"] == "unauthorized"
    end
  end

  # --- define_rule_set_rule / define_prompt_template / define_legend ------

  describe "define_rule_set_rule / define_prompt_template / define_legend (cap-#1)" do
    setup do
      flavor = register_test_flavor()
      backend_uri = URI.new!("template://team-alpha/agent/mcp-wm-backend-#{uniq()}")
      :ok = create_agent_template(backend_uri, flavor, "wm-backend")

      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()

      caps =
        orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      mcp = mcp_server(session_uri, orchestrator_uri, caps)

      # A member must exist so the receiver role_name resolves.
      add =
        McpServer.handle_tool_call(mcp, "add_managed_member", %{
          "source_agent_template_uri" => URI.to_string(backend_uri),
          "role_name" => "wm-dev"
        })

      refute add["isError"]

      %{mcp: mcp, session_uri: session_uri}
    end

    test "define_rule_set_rule writes a single-receiver rule and returns its id", ctx do
      result =
        McpServer.handle_tool_call(ctx.mcp, "define_rule_set_rule", %{
          "matcher_ast" => %{"type" => "text_contains", "arg" => "ship"},
          "receiver_role_name" => "wm-dev",
          "rule_set" => "ship-rs",
          "position" => 0
        })

      refute result["isError"], "define_rule_set_rule failed: #{inspect(result)}"
      assert is_integer(result["structuredContent"]["id"])
    end

    test "define_prompt_template installs a named template on the session", ctx do
      result =
        McpServer.handle_tool_call(ctx.mcp, "define_prompt_template", %{
          "name" => "hop",
          "template" => "接龙：{body}"
        })

      refute result["isError"], "define_prompt_template failed: #{inspect(result)}"
      assert chat_slice(ctx.session_uri).prompt_templates["hop"] == "接龙：{body}"
    end

    test "define_legend fronts a rule-set with a @legend handle", ctx do
      result =
        McpServer.handle_tool_call(ctx.mcp, "define_legend", %{
          "legend_name" => "team-x",
          "member_role_names" => ["wm-dev"],
          "bound_rule_set" => "ship-rs",
          "fold" => true
        })

      refute result["isError"], "define_legend failed: #{inspect(result)}"

      assert {:ok, %{bound_rule_set: "ship-rs"}} =
               Behavior.Chat.resolve_legend(chat_slice(ctx.session_uri), "team-x")
    end

    test "define_rule_set_rule with an unknown receiver role → structured error (codex M1)",
         ctx do
      result =
        McpServer.handle_tool_call(ctx.mcp, "define_rule_set_rule", %{
          "matcher_ast" => %{"type" => "text_contains", "arg" => "x"},
          "receiver_role_name" => "ghost-role-#{uniq()}",
          "rule_set" => "rs"
        })

      assert result["isError"] == true
      # codex M1 — a dangling role_name is now rejected as a non-member role
      # (it MUST resolve to a current session member), not parsed as a URI.
      assert result["error"]["code"] == "unknown_member_role"
    end

    test "define_rule_set_rule with a URI-shaped non-member receiver is rejected (codex M1 bypass)",
         ctx do
      # Pre-fix this URI-shaped string fell through to URI parsing and bound
      # a NON-MEMBER receiver. It must now be rejected as a non-member role.
      result =
        McpServer.handle_tool_call(ctx.mcp, "define_rule_set_rule", %{
          "matcher_ast" => %{"type" => "text_contains", "arg" => "x"},
          "receiver_role_name" => "entity://team-alpha/agent/not_a_member_#{uniq()}",
          "rule_set" => "rs"
        })

      assert result["isError"] == true
      assert result["error"]["code"] == "unknown_member_role"
    end
  end

  # --- update_template / save_template_as effect -------------------------

  describe "update_template / save_template_as persist real kind_snapshots rows" do
    setup do
      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()

      caps =
        orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      %{session_uri: session_uri, orchestrator_uri: orchestrator_uri, caps: caps}
    end

    test "save_template_as persists a new SessionTemplate Kind + snapshot row", ctx do
      mcp = mcp_server(ctx.session_uri, ctx.orchestrator_uri, ctx.caps)
      new_name = "mcp-saved-#{uniq()}"

      result = McpServer.handle_tool_call(mcp, "save_template_as", %{"new_name" => new_name})

      refute result["isError"], "save_template_as failed: #{inspect(result)}"
      uri_str = result["structuredContent"]

      # A real kind_snapshots row exists for the persisted version.
      assert %Ezagent.Ecto.KindSnapshot{kind_type: "session_template"} =
               Ezagent.Ecto.KindSnapshot.get(uri_str)
    end

    test "update_template persists a new version of the parent SessionTemplate", ctx do
      # Persist a parent SessionTemplate first.
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

      mcp =
        mcp_server(ctx.session_uri, ctx.orchestrator_uri, ctx.caps,
          parent_template_uri: parent_uri
        )

      result = McpServer.handle_tool_call(mcp, "update_template", %{})

      refute result["isError"], "update_template failed: #{inspect(result)}"
      new_uri_str = result["structuredContent"]

      # The new version is a real, distinct kind_snapshots row.
      assert %Ezagent.Ecto.KindSnapshot{kind_type: "session_template"} =
               Ezagent.Ecto.KindSnapshot.get(new_uri_str)
    end

    test "update_template with a deleted parent → structured parent-gone MCP error", ctx do
      mcp =
        mcp_server(ctx.session_uri, ctx.orchestrator_uri, ctx.caps,
          parent_template_uri:
            Ezagent.URI.new!("template://team-alpha/session/never-existed-#{uniq()}@deadbeef")
        )

      result = McpServer.handle_tool_call(mcp, "update_template", %{})

      assert result["isError"] == true
      assert result["error"]["code"] == "parent_template_deleted"
    end
  end

  # --- unknown-tool + arg-error mapping ----------------------------------

  describe "structured error mapping at the MCP boundary" do
    test "an unknown tool name → structured unknown_tool error" do
      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()
      caps = orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [])
      mcp = mcp_server(session_uri, orchestrator_uri, caps)

      result = McpServer.handle_tool_call(mcp, "not_a_real_tool", %{})

      assert result["isError"] == true
      assert result["error"]["code"] == "unknown_tool"
    end

    test "a missing required argument → structured invalid_arguments error" do
      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()

      caps =
        orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [:agent_template])

      mcp = mcp_server(session_uri, orchestrator_uri, caps)

      # add_managed_member without source_agent_template_uri.
      result = McpServer.handle_tool_call(mcp, "add_managed_member", %{"role_name" => "x"})

      assert result["isError"] == true
      assert result["error"]["code"] == "invalid_arguments"
    end
  end

  # --- the GenServer process form ----------------------------------------

  describe "McpServer as a process" do
    test "start_link + tool_call run a tool against the bound context" do
      flavor = register_test_flavor()
      backend_uri = URI.new!("template://team-alpha/agent/mcp-proc-#{uniq()}")
      :ok = create_agent_template(backend_uri, flavor, "proc-worker")

      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()

      caps =
        orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      {:ok, pid} =
        McpServer.start_link(
          orchestrator_uri: orchestrator_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          caps: caps
        )

      result =
        McpServer.tool_call(pid, "add_managed_member", %{
          "source_agent_template_uri" => URI.to_string(backend_uri),
          "role_name" => "proc-role"
        })

      refute result["isError"], "process-form tool_call failed: #{inspect(result)}"

      # The bound context is readable.
      bound = McpServer.context(pid)
      assert bound.orchestrator_uri == orchestrator_uri
      assert bound.session_uri == session_uri

      GenServer.stop(pid)
    end
  end
end
