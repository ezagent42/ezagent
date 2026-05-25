defmodule EzagentDomainChat.Integration.OrchestratorMcpE2eTest do
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
      agent_uri = URI.parse(uri_str)

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
    target = URI.parse("#{URI.to_string(uri)}?action=#{action}")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: User.admin_caps(),
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
      working_directory: "/tmp/mcp-e2e",
      claude_config_dir: nil,
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
    session_uri =
      URI.parse("session://generic/team-alpha/mcp-e2e-#{uniq()}")

    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    session_uri
  end

  # Spawn an orchestrator Agent Kind (the cc-flavored agent the
  # Generator would have spawned).
  defp spawn_orchestrator do
    orchestrator_uri =
      URI.parse("entity://agent/team-alpha/cc_orch-#{uniq()}")

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

  # Read the durable template_working_copy off the live Session.
  defp session_working_copy(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)

    chat_slice =
      pid
      |> :sys.get_state()
      |> Map.get(:state, %{})
      |> Map.get(:chat, %{})

    Behavior.Chat.template_working_copy(chat_slice)
  end

  # --- the MCP-server tool schema surface --------------------------------

  describe "the orchestrator MCP server exposes exactly the 7 tools" do
    test "tool_schemas/0 has one valid JSON schema per the 7 tools" do
      schemas = McpServer.tool_schemas()

      assert length(schemas) == 7

      names = Enum.map(schemas, & &1["name"]) |> MapSet.new()

      assert names ==
               MapSet.new(~w(add_agent_slot remove_agent_slot update_agent_template
                             write_matcher update_template save_template_as list_templates))

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
          parent_template_uri: URI.parse("template://session/team-alpha/x@abc")
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
      at_uri = URI.new!("template://agent/team-alpha/mcp-list-at-#{uniq()}")
      :ok = create_agent_template(at_uri, flavor, "list-worker")

      st_content = %{
        name: "mcp-list-st-#{uniq()}",
        description: "list test team",
        agent_slots: [],
        routing_rules: [],
        orchestrator_template_uri: URI.parse("template://agent/system/cc-orchestrator"),
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
        orchestrator_caps(ctx.session_uri, ctx.orchestrator_uri, @workspace_uri, [:session_template])

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

  describe "add_agent_slot / remove_agent_slot / update_agent_template (cap-#2 path)" do
    setup do
      flavor = register_test_flavor()

      backend_uri = URI.new!("template://agent/team-alpha/mcp-backend-#{uniq()}")
      replacement_uri = URI.new!("template://agent/team-alpha/mcp-replacement-#{uniq()}")
      :ok = create_agent_template(backend_uri, flavor, "backend")
      :ok = create_agent_template(replacement_uri, flavor, "replacement")

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
        replacement_uri: replacement_uri,
        mcp: mcp
      }
    end

    test "add_agent_slot spawns a worker, records it under the orchestrator + updates the slice",
         ctx do
      result =
        McpServer.handle_tool_call(ctx.mcp, "add_agent_slot", %{
          "slot_name" => "backend-dev",
          "agent_template_uri" => URI.to_string(ctx.backend_uri)
        })

      refute result["isError"], "add_agent_slot failed: #{inspect(result)}"
      worker_uri_str = result["structuredContent"]

      # The worker is in AgentLineage UNDER THE ORCHESTRATOR — this is
      # what makes cap #2 resolve for the remove/update tools.
      assert AgentLineage.spawned_in_lineage?(
               URI.parse(worker_uri_str),
               ctx.orchestrator_uri
             ),
             "the spawned worker must be recorded under the orchestrator's lineage " <>
               "(§1.6a) — cap #2 depends on it"

      # The durable template_working_copy.agent_slots carries the slot.
      # Phase 7 hardening — agent_slots is the 4-tuple
      # {slot_name, source_agent_template_uri, live_worker_uri, generation}.
      wc = session_working_copy(ctx.session_uri)

      assert {"backend-dev", _src, _live, _gen} =
               Enum.find(wc.agent_slots, &(elem(&1, 0) == "backend-dev"))
    end

    test "remove_agent_slot terminates the orchestrator's own worker (cap-#2 happy path)", ctx do
      add =
        McpServer.handle_tool_call(ctx.mcp, "add_agent_slot", %{
          "slot_name" => "rm-slot",
          "agent_template_uri" => URI.to_string(ctx.backend_uri)
        })

      refute add["isError"]

      result = McpServer.handle_tool_call(ctx.mcp, "remove_agent_slot", %{"slot_name" => "rm-slot"})

      refute result["isError"],
             "remove_agent_slot on the orchestrator's OWN worker must SUCCEED — " <>
               "cap #2 ({:spawned_by, orchestrator}) authorizes it. Got: #{inspect(result)}"

      # The slot is gone from the working copy.
      wc = session_working_copy(ctx.session_uri)
      refute Enum.any?(wc.agent_slots, &(elem(&1, 0) == "rm-slot"))
    end

    test "remove_agent_slot of an absent slot is idempotent success", ctx do
      result =
        McpServer.handle_tool_call(ctx.mcp, "remove_agent_slot", %{
          "slot_name" => "never-existed-#{uniq()}"
        })

      refute result["isError"]
    end

    test "update_agent_template swaps the slot's template, rollback-safe (cap-#2 + cap-#4)", ctx do
      add =
        McpServer.handle_tool_call(ctx.mcp, "add_agent_slot", %{
          "slot_name" => "upd-slot",
          "agent_template_uri" => URI.to_string(ctx.backend_uri)
        })

      refute add["isError"]

      result =
        McpServer.handle_tool_call(ctx.mcp, "update_agent_template", %{
          "slot_name" => "upd-slot",
          "new_agent_template_uri" => URI.to_string(ctx.replacement_uri)
        })

      refute result["isError"],
             "update_agent_template on the orchestrator's own slot must SUCCEED. " <>
               "Got: #{inspect(result)}"

      # The slot tuple now points at the REPLACEMENT AgentTemplate URI,
      # carries a NEW live worker URI, and a bumped generation (HIGH-6).
      wc = session_working_copy(ctx.session_uri)

      {"upd-slot", new_src, new_live, new_gen} =
        Enum.find(wc.agent_slots, &(elem(&1, 0) == "upd-slot"))

      assert URI.to_string(new_src) == URI.to_string(ctx.replacement_uri)
      assert new_gen == 1, "a same-flavor swap bumps the slot's generation"
      assert %URI{scheme: "entity"} = new_live
    end

    test "cap-#2 CONTROL — another orchestrator cannot remove this orchestrator's worker", ctx do
      # Orchestrator A spawns a worker.
      add =
        McpServer.handle_tool_call(ctx.mcp, "add_agent_slot", %{
          "slot_name" => "owned-by-a",
          "agent_template_uri" => URI.to_string(ctx.backend_uri)
        })

      refute add["isError"]

      # Orchestrator B — a DIFFERENT orchestrator — gets a cap #2 scoped
      # to ITSELF, and an MCP server bound to the SAME session (so the
      # slot is visible) but its OWN orchestrator URI.
      orchestrator_b = spawn_orchestrator()

      caps_b =
        orchestrator_caps(ctx.session_uri, orchestrator_b, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      mcp_b = mcp_server(ctx.session_uri, orchestrator_b, caps_b)

      result = McpServer.handle_tool_call(mcp_b, "remove_agent_slot", %{"slot_name" => "owned-by-a"})

      assert result["isError"] == true,
             "orchestrator B must NOT be able to terminate orchestrator A's worker — " <>
               "cap #2 is {:spawned_by, B}, the worker is spawned_by A. Got: #{inspect(result)}"

      assert result["error"]["code"] == "unauthorized"
    end
  end

  # --- write_matcher -----------------------------------------------------

  describe "write_matcher dispatches routing.add_rule on the session (cap-#1)" do
    setup do
      flavor = register_test_flavor()
      backend_uri = URI.new!("template://agent/team-alpha/mcp-wm-backend-#{uniq()}")
      :ok = create_agent_template(backend_uri, flavor, "wm-backend")

      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()

      caps =
        orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri, [
          :agent_template,
          :session_template
        ])

      mcp = mcp_server(session_uri, orchestrator_uri, caps)

      # A slot must exist so the receiver slot name resolves.
      add =
        McpServer.handle_tool_call(mcp, "add_agent_slot", %{
          "slot_name" => "wm-dev",
          "agent_template_uri" => URI.to_string(backend_uri)
        })

      refute add["isError"]

      %{mcp: mcp, session_uri: session_uri}
    end

    test "write_matcher writes a routing rule and returns its id", ctx do
      result =
        McpServer.handle_tool_call(ctx.mcp, "write_matcher", %{
          "matcher_ast" => %{"type" => "text_contains", "arg" => "ship"},
          "receiver_slot_names" => ["wm-dev"]
        })

      refute result["isError"], "write_matcher failed: #{inspect(result)}"
      assert is_integer(result["structuredContent"]["id"])
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
        orchestrator_template_uri: URI.parse("template://agent/system/cc-orchestrator"),
        default_workspace_uri: @workspace_uri,
        parent_template_uri: nil,
        created_by: User.admin_uri(),
        created_at: ~U[2026-05-22 00:00:00Z]
      }

      {:ok, parent_uri} = SessionTemplate.persist_version(parent_content, "team-alpha")

      mcp =
        mcp_server(ctx.session_uri, ctx.orchestrator_uri, ctx.caps, parent_template_uri: parent_uri)

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
            URI.parse("template://session/team-alpha/never-existed-#{uniq()}@deadbeef")
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

      # add_agent_slot without agent_template_uri.
      result = McpServer.handle_tool_call(mcp, "add_agent_slot", %{"slot_name" => "x"})

      assert result["isError"] == true
      assert result["error"]["code"] == "invalid_arguments"
    end
  end

  # --- the GenServer process form ----------------------------------------

  describe "McpServer as a process" do
    test "start_link + tool_call run a tool against the bound context" do
      flavor = register_test_flavor()
      backend_uri = URI.new!("template://agent/team-alpha/mcp-proc-#{uniq()}")
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
        McpServer.tool_call(pid, "add_agent_slot", %{
          "slot_name" => "proc-slot",
          "agent_template_uri" => URI.to_string(backend_uri)
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
