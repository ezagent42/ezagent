defmodule EzagentDomainInstanceMessage.Integration.OrchestratorToolsOpsTest do
  @moduledoc """
  The AUTH-NET for the orchestrator tool OPERATIONS (decomposition spec
  §3.4 / O-4 — operations live in `domain.session`).

  Relocated from the cc plugin's `orchestrator_mcp_e2e_test.exs` when PR-8
  moved `Ezagent.Orchestrator.Tools` BACK to the session domain (the cc
  plugin keeps only the MCP TRANSPORT). This drives the VALUE-FORM
  operation core `Ezagent.Orchestrator.ToolRunner.run_tool/3` directly with
  EXPLICIT caller `opts` — exactly the caller context the session-side
  `Ezagent.Behavior.OrchestratorTools` action reconstructs before calling
  it. Asserting on the RAW `{:ok, _}` / `{:error, _}` result (the cc
  transport's MCP encoding of that result is tested in the cc plugin's
  transport test).

  ## What it proves (the SAME auth contract, raw)

  1. **No-`admin_caps`-fallback denial** — `list_templates` / `update_template`
     with caps #3/#4 OMITTED returns `{:error, :unauthorized}`. If the op
     path fell back to ambient `admin_caps` this would succeed; it must NOT.
  2. **cap-#2 happy path / deny** — `remove_member` on a worker THIS
     orchestrator spawned SUCCEEDS; the control against ANOTHER
     orchestrator's worker returns `{:error, :unauthorized}`.
  3. **per-kind list (MEDIUM-5)** — a cap-#3-only caller sees
     `session_templates` but NOT `agent_templates`; cap-#4-only the inverse.
  4. **per-tool effects** — each tool produces its intended effect.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentFlavorRegistry, AgentLineage, Behavior, Capability, KindRegistry}
  alias Ezagent.Entity.{Agent, Session, SessionTemplate, User}
  alias Ezagent.Orchestrator.ToolRunner

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
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
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
  # #1 within_session, #2 spawned_by, #3 session_template, #4 agent_template.
  # `template_kinds` selects which template caps are present — the
  # no-fallback denial test omits #3/#4 by passing `[]`.
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
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    session_uri
  end

  defp spawn_orchestrator do
    orchestrator_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-#{uniq()}")

    :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")
    on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(orchestrator_uri) end)

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)
    orchestrator_uri
  end

  # Build the orchestrator's caller `opts` — the EXACT context the
  # session-side `OrchestratorTools` action reconstructs.
  defp tool_opts(session_uri, orchestrator_uri, caps, opts \\ []) do
    [
      caller: orchestrator_uri,
      caps: caps,
      session_uri: session_uri,
      workspace_uri: @workspace_uri,
      owner: orchestrator_uri,
      parent_template_uri: Keyword.get(opts, :parent_template_uri)
    ]
  end

  # Run a tool through the value-form core. Returns the RAW result.
  defp run_tool(opts, tool, args) when is_binary(tool) do
    tool_atom = ToolRunner.normalize_tool(tool)
    refute is_nil(tool_atom), "unknown tool name in test: #{tool}"
    ToolRunner.run_tool(tool_atom, args, opts)
  end

  defp chat_slice(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: slice}}} = :sys.get_state(pid)
    slice
  end

  describe "the orchestrator tool surface (§3.8 member/rule-set + template tools)" do
    test "ToolRunner.tool_names/0 is the 9-tool member + rule-set + template set" do
      assert MapSet.new(ToolRunner.tool_names()) ==
               MapSet.new([
                 :add_managed_member,
                 :update_member_template,
                 :remove_member,
                 :define_rule_set_rule,
                 :define_prompt_template,
                 :define_legend,
                 :update_template,
                 :save_template_as,
                 :list_templates
               ])
    end
  end

  describe "no admin_caps fallback — caps #3/#4 omitted denies (SPEC §2 PR-5 HIGH-1)" do
    test "list_templates with caps #3/#4 OMITTED → {:error, :unauthorized}" do
      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()

      caps = orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [])
      opts = tool_opts(session_uri, orchestrator_uri, caps)

      assert {:error, :unauthorized} = run_tool(opts, "list_templates", %{}),
             "list_templates with NO template caps must FAIL — if it succeeded the " <>
               "op path fell back to ambient admin_caps (forbidden)."
    end

    test "update_template with cap #3 OMITTED → {:error, :unauthorized}" do
      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()

      caps = orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [])

      opts =
        tool_opts(session_uri, orchestrator_uri, caps,
          parent_template_uri: Ezagent.URI.new!("template://team-alpha/session/x@abc")
        )

      assert {:error, :unauthorized} = run_tool(opts, "update_template", %{})
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

      opts = tool_opts(ctx.session_uri, ctx.orchestrator_uri, caps)
      assert {:ok, structured} = run_tool(opts, "list_templates", %{})

      assert ctx.agent_template_uri in structured.agent_templates

      assert structured.session_templates == [],
             "cap-#4-only caller must NOT see session templates — cross-kind leak."
    end

    test "cap-#3-only caller sees ONLY session_templates, NOT agent_templates", ctx do
      caps =
        orchestrator_caps(ctx.session_uri, ctx.orchestrator_uri, @workspace_uri, [:session_template])

      opts = tool_opts(ctx.session_uri, ctx.orchestrator_uri, caps)
      assert {:ok, structured} = run_tool(opts, "list_templates", %{})

      assert ctx.session_template_uri in structured.session_templates

      assert structured.agent_templates == [],
             "cap-#3-only caller must NOT see agent templates — cross-kind leak."
    end

    test "caller with both caps #3 + #4 sees both kinds", ctx do
      caps =
        orchestrator_caps(ctx.session_uri, ctx.orchestrator_uri, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      opts = tool_opts(ctx.session_uri, ctx.orchestrator_uri, caps)
      assert {:ok, structured} = run_tool(opts, "list_templates", %{})

      assert ctx.agent_template_uri in structured.agent_templates
      assert ctx.session_template_uri in structured.session_templates
    end
  end

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

      opts = tool_opts(session_uri, orchestrator_uri, caps)

      %{
        flavor: flavor,
        session_uri: session_uri,
        orchestrator_uri: orchestrator_uri,
        backend_uri: backend_uri,
        opts: opts
      }
    end

    test "add_managed_member spawns a worker, records it under the orchestrator + joins it", ctx do
      assert {:ok, %URI{} = member_uri} =
               run_tool(ctx.opts, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
                 "role_name" => "backend-dev",
                 "in_session_template" => true
               })

      assert AgentLineage.spawned_in_lineage?(member_uri, ctx.orchestrator_uri),
             "the spawned member must be recorded under the orchestrator's lineage — cap #2 depends on it"

      slice = chat_slice(ctx.session_uri)
      resolved = Behavior.Session.role_name_to_uri(slice.members, "backend-dev")
      assert URI.to_string(resolved) == URI.to_string(member_uri)
      assert slice.members[resolved].in_session_template == true
      assert slice.members[resolved].source_template_uri == ctx.backend_uri
    end

    test "remove_member terminates the orchestrator's own worker (cap-#2 happy path)", ctx do
      assert {:ok, _} =
               run_tool(ctx.opts, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
                 "role_name" => "rm-role"
               })

      assert {:ok, %{status: status}} =
               run_tool(ctx.opts, "remove_member", %{"role_name" => "rm-role"})

      assert status in [:removed, "removed"]

      slice = chat_slice(ctx.session_uri)
      refute Behavior.Session.role_name_to_uri(slice.members, "rm-role")
    end

    test "remove_member of an absent role is idempotent success", ctx do
      assert {:ok, _} =
               run_tool(ctx.opts, "remove_member", %{"role_name" => "never-existed-#{uniq()}"})
    end

    test "remove_member of a rule's SOLE receiver reports deleted_rules:1 + logs a warning", ctx do
      assert {:ok, _} =
               run_tool(ctx.opts, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
                 "role_name" => "sole-dev"
               })

      assert {:ok, %{id: rule_id}} =
               run_tool(ctx.opts, "define_rule_set_rule", %{
                 "matcher_ast" => %{"type" => "text_contains", "arg" => "deploy"},
                 "receiver_role_name" => "sole-dev",
                 "rule_set" => "deploy-rs"
               })

      assert is_integer(rule_id)

      table = EzagentDomainInstanceMessage.Routing.MentionRouting
      assert Enum.any?(Ezagent.Routing.RuleStore.list(table), &(&1.id == rule_id))

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          run_tool(ctx.opts, "remove_member", %{"role_name" => "sole-dev"})
        end)

      assert {:ok, %{deleted_rules: 1, repointed_rules: 0}} = result
      assert log =~ "force-deleted routing rule"
      assert log =~ "ZERO receivers"
      refute Enum.any?(Ezagent.Routing.RuleStore.list(table), &(&1.id == rule_id))
    end

    test "remove_member of ONE of several receivers reports repointed_rules:1, rule survives", ctx do
      assert {:ok, %URI{} = keep_a} =
               run_tool(ctx.opts, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
                 "role_name" => "keep-a"
               })

      assert {:ok, %URI{} = keep_b} =
               run_tool(ctx.opts, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
                 "role_name" => "keep-b"
               })

      keep_b_str = URI.to_string(keep_b)

      {:ok, %Ezagent.Routing.RuleStore{id: rule_id}} =
        Ezagent.Routing.RuleStore.add(
          EzagentDomainInstanceMessage.Routing.MentionRouting,
          {:text_contains, "review"},
          [URI.to_string(keep_a), keep_b_str],
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
          run_tool(ctx.opts, "remove_member", %{"role_name" => "keep-a"})
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
               run_tool(ctx.opts, "add_managed_member", %{
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

      assert {:ok, _} = run_tool(ctx.opts, "remove_member", %{"role_name" => "scoped-dev"})

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
               run_tool(ctx.opts, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(ctx.backend_uri),
                 "role_name" => "owned-by-a"
               })

      orchestrator_b = spawn_orchestrator()

      caps_b =
        orchestrator_caps(ctx.session_uri, orchestrator_b, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      opts_b = tool_opts(ctx.session_uri, orchestrator_b, caps_b)

      assert {:error, :unauthorized} =
               run_tool(opts_b, "remove_member", %{"role_name" => "owned-by-a"}),
             "orchestrator B must NOT be able to terminate orchestrator A's member — " <>
               "cap #2 is {:spawned_by, B}, the member is spawned_by A."
    end
  end

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

      opts = tool_opts(session_uri, orchestrator_uri, caps)

      assert {:ok, _} =
               run_tool(opts, "add_managed_member", %{
                 "source_agent_template_uri" => URI.to_string(backend_uri),
                 "role_name" => "wm-dev"
               })

      %{opts: opts, session_uri: session_uri}
    end

    test "define_rule_set_rule writes a single-receiver rule and returns its id", ctx do
      assert {:ok, %{id: id}} =
               run_tool(ctx.opts, "define_rule_set_rule", %{
                 "matcher_ast" => %{"type" => "text_contains", "arg" => "ship"},
                 "receiver_role_name" => "wm-dev",
                 "rule_set" => "ship-rs",
                 "position" => 0
               })

      assert is_integer(id)
    end

    test "define_prompt_template installs a named template on the session", ctx do
      assert {:ok, _} =
               run_tool(ctx.opts, "define_prompt_template", %{
                 "name" => "hop",
                 "template" => "接龙：{body}"
               })

      assert chat_slice(ctx.session_uri).prompt_templates["hop"] == "接龙：{body}"
    end

    test "define_legend fronts a rule-set with a @legend handle", ctx do
      assert {:ok, _} =
               run_tool(ctx.opts, "define_legend", %{
                 "legend_name" => "team-x",
                 "member_role_names" => ["wm-dev"],
                 "bound_rule_set" => "ship-rs",
                 "fold" => true
               })

      assert {:ok, %{bound_rule_set: "ship-rs"}} =
               Behavior.Session.resolve_legend(chat_slice(ctx.session_uri), "team-x")
    end

    test "define_rule_set_rule with an unknown receiver role → {:error, {:unknown_member_role, _}}",
         ctx do
      assert {:error, {:unknown_member_role, _}} =
               run_tool(ctx.opts, "define_rule_set_rule", %{
                 "matcher_ast" => %{"type" => "text_contains", "arg" => "x"},
                 "receiver_role_name" => "ghost-role-#{uniq()}",
                 "rule_set" => "rs"
               })
    end

    test "define_rule_set_rule with a URI-shaped non-member receiver is rejected (codex M1 bypass)",
         ctx do
      assert {:error, {:unknown_member_role, _}} =
               run_tool(ctx.opts, "define_rule_set_rule", %{
                 "matcher_ast" => %{"type" => "text_contains", "arg" => "x"},
                 "receiver_role_name" => "entity://team-alpha/agent/not_a_member_#{uniq()}",
                 "rule_set" => "rs"
               })
    end
  end

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
      opts = tool_opts(ctx.session_uri, ctx.orchestrator_uri, ctx.caps)
      new_name = "mcp-saved-#{uniq()}"

      assert {:ok, %URI{} = uri} = run_tool(opts, "save_template_as", %{"new_name" => new_name})

      assert %Ezagent.Ecto.KindSnapshot{kind_type: "session_template"} =
               Ezagent.Ecto.KindSnapshot.get(URI.to_string(uri))
    end

    test "update_template persists a new version of the parent SessionTemplate", ctx do
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

      opts =
        tool_opts(ctx.session_uri, ctx.orchestrator_uri, ctx.caps, parent_template_uri: parent_uri)

      assert {:ok, %URI{} = new_uri} = run_tool(opts, "update_template", %{})

      assert %Ezagent.Ecto.KindSnapshot{kind_type: "session_template"} =
               Ezagent.Ecto.KindSnapshot.get(URI.to_string(new_uri))
    end

    test "update_template with a deleted parent → {:error, :parent_template_deleted}", ctx do
      opts =
        tool_opts(ctx.session_uri, ctx.orchestrator_uri, ctx.caps,
          parent_template_uri:
            Ezagent.URI.new!("template://team-alpha/session/never-existed-#{uniq()}@deadbeef")
        )

      assert {:error, :parent_template_deleted} = run_tool(opts, "update_template", %{})
    end
  end

  describe "operation-core argument errors" do
    test "an unknown tool name normalizes to nil" do
      assert ToolRunner.normalize_tool("not_a_real_tool") == nil
    end

    test "a missing required argument → {:error, {:missing_arg, _}}" do
      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()

      caps = orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [:agent_template])
      opts = tool_opts(session_uri, orchestrator_uri, caps)

      assert {:error, {:missing_arg, "source_agent_template_uri"}} =
               run_tool(opts, "add_managed_member", %{"role_name" => "x"})
    end
  end
end
