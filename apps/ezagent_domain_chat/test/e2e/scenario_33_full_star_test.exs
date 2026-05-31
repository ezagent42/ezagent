defmodule EzagentDomainChat.E2E.Scenario33_FullStarTest do
  @moduledoc """
  E2E Scenario 33 — full-star: the orchestrator dispatches a worker of
  EACH agent flavor (`docs/scenarios/33-full-star-orchestrator-all-flavors`).

  This is the **deterministic invariant gate** (the scenario's
  Verification tier 1). It proves the orchestrator can compose a team of
  THREE DISTINCT flavors — the `cc` / `codex` / `curl` matrix Scenario 33
  targets — via its `add_agent_slot` MCP tool: each worker is spawned,
  recorded under THIS orchestrator's lineage (so cap #2 authorizes
  managing it), and carried as a distinct slot in the durable
  `template_working_copy.agent_slots`. All three coexist + route
  independently (`write_matcher`).

  Per the scenario doc, the automated tier "may stub the provider call
  where a live provider isn't available in CI": the three flavors here
  are no-PTY synthetic stand-ins (the worker Kind is the plain
  `Ezagent.Entity.Agent`), exactly as the sibling
  `orchestrator_mcp_e2e_test` does for a single flavor. What this pins is
  the orchestrator's per-flavor SLOT/spawn/lineage machinery — flavor
  count = 3, distinct flavor names, distinct slots — NOT the real
  cc/codex/curl PTY+provider round-trip.

  The real cc/codex/curl PTY + provider reply + Feishu-group mirror is
  the scenario's **LIVE tier** (the true gate, Standard 3 in
  `feedback_esr_e2e_standards`): it requires the cc/codex/curl worker
  AgentTemplates seeded + live provider creds, and a real `@orch` Feishu
  message whose round-trip is visible in the bound group. That tier is
  NOT this CI test (see the scenario doc's "Provider prerequisites").
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentFlavorRegistry, AgentLineage, Behavior, Capability, KindRegistry}
  alias Ezagent.Entity.{Agent, Session, User}
  alias Ezagent.Orchestrator.McpServer

  @moduletag scenario: "33-full-star-orchestrator-all-flavors"

  @workspace_uri URI.new!("workspace://team-alpha")

  # A no-PTY Template Class: the worker Kind is the plain Agent (no
  # claude/codex/curl subprocess). Mirrors orchestrator_mcp_e2e_test's
  # TestFlavorClass. `instantiate/3` reports the real freshness signal
  # from the atomic spawn (update_agent_template's swap depends on it).
  defmodule StubFlavorClass do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "scenario33.stub.agent"

    @impl true
    def validate(tmpl) when is_map(tmpl),
      do: if(Map.has_key?(tmpl, "agent_uri"), do: :ok, else: {:error, :missing_agent_uri})

    def validate(_), do: {:error, :not_a_map}

    @impl true
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

  defp uniq, do: System.unique_integer([:positive])

  # Register a synthetic flavor standing in for one of the real
  # cc/codex/curl flavors (so the test exercises the per-flavor slot
  # machinery without a real provider). The flavor name is the `<flavor>`
  # prefix the worker URI carries.
  defp register_stub_flavor(label) do
    flavor = "s33#{label}#{uniq()}"
    :ok = AgentFlavorRegistry.register(%{flavor: flavor, kind: Agent, template_class: StubFlavorClass})
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
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp create_agent_template(uri, flavor, name) do
    content = %{
      name: name,
      description: "scenario33 worker #{name}",
      flavor: flavor,
      working_directory: "/tmp/scenario33",
      claude_config_dir: nil,
      settings_path: nil,
      mcp_config_path: nil,
      api_key_helper: nil,
      default_caps: [],
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z]
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

  # The four delegated caps the Generator grants an orchestrator.
  defp orchestrator_caps(session_uri, orchestrator_uri, workspace_uri) do
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

    MapSet.new(base ++ [template_cap(:agent_template, workspace_uri), template_cap(:session_template, workspace_uri)])
  end

  defp spawn_session do
    session_uri = URI.parse("session://generic/team-alpha/s33-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    session_uri
  end

  defp spawn_orchestrator do
    orchestrator_uri = URI.parse("entity://agent/team-alpha/cc_orch-s33-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)
    orchestrator_uri
  end

  defp mcp_server(session_uri, orchestrator_uri, caps) do
    {:ok, ctx} =
      McpServer.new(
        orchestrator_uri: orchestrator_uri,
        session_uri: session_uri,
        workspace_uri: @workspace_uri,
        caps: caps
      )

    ctx
  end

  defp session_working_copy(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)

    chat_slice =
      pid
      |> :sys.get_state()
      |> Map.get(:state, %{})
      |> Map.get(:chat, %{})
      |> then(&Map.get(&1, :state, &1))

    Behavior.Chat.template_working_copy(chat_slice)
  end

  describe "orchestrator composes a 3-flavor team (cc + codex + curl stand-ins)" do
    setup do
      # Three DISTINCT flavors standing in for cc / codex / curl.
      flavors = %{
        cc: register_stub_flavor("cc"),
        codex: register_stub_flavor("codex"),
        curl: register_stub_flavor("curl")
      }

      templates =
        Map.new(flavors, fn {label, flavor} ->
          uri = URI.new!("template://agent/team-alpha/s33-#{label}-#{uniq()}")
          :ok = create_agent_template(uri, flavor, "worker-#{label}")
          {label, uri}
        end)

      session_uri = spawn_session()
      orchestrator_uri = spawn_orchestrator()
      caps = orchestrator_caps(session_uri, orchestrator_uri, @workspace_uri)
      mcp = mcp_server(session_uri, orchestrator_uri, caps)

      %{mcp: mcp, session_uri: session_uri, orchestrator_uri: orchestrator_uri, templates: templates}
    end

    test "add_agent_slot spawns one worker per flavor, each under the orchestrator lineage", ctx do
      slots = [{"worker-cc", ctx.templates.cc}, {"worker-codex", ctx.templates.codex}, {"worker-ds", ctx.templates.curl}]

      worker_uris =
        for {slot_name, tmpl_uri} <- slots do
          result =
            McpServer.handle_tool_call(ctx.mcp, "add_agent_slot", %{
              "slot_name" => slot_name,
              "agent_template_uri" => URI.to_string(tmpl_uri)
            })

          refute result["isError"], "add_agent_slot #{slot_name} failed: #{inspect(result)}"
          worker_uri = URI.parse(result["structuredContent"])

          assert AgentLineage.spawned_in_lineage?(worker_uri, ctx.orchestrator_uri),
                 "#{slot_name} worker must be recorded under the orchestrator lineage (cap #2)"

          {slot_name, worker_uri}
        end

      # All THREE slots coexist in the durable working copy — the
      # full-star team, one slot per flavor.
      wc = session_working_copy(ctx.session_uri)
      slot_names = Enum.map(wc.agent_slots, &elem(&1, 0)) |> MapSet.new()

      for {slot_name, _} <- slots do
        assert MapSet.member?(slot_names, slot_name),
               "slot #{slot_name} must be present in template_working_copy.agent_slots — got #{inspect(slot_names)}"
      end

      # The three workers are distinct entities.
      uris = Enum.map(worker_uris, fn {_, u} -> URI.to_string(u) end)
      assert length(Enum.uniq(uris)) == 3, "the three flavor workers must be distinct: #{inspect(uris)}"
    end

    test "write_matcher routes to each flavor slot independently", ctx do
      for {slot_name, tmpl_uri} <- [{"wm-cc", ctx.templates.cc}, {"wm-codex", ctx.templates.codex}, {"wm-ds", ctx.templates.curl}] do
        add =
          McpServer.handle_tool_call(ctx.mcp, "add_agent_slot", %{
            "slot_name" => slot_name,
            "agent_template_uri" => URI.to_string(tmpl_uri)
          })

        refute add["isError"], "add_agent_slot #{slot_name} failed: #{inspect(add)}"

        wm =
          McpServer.handle_tool_call(ctx.mcp, "write_matcher", %{
            "matcher_ast" => %{"type" => "text_contains", "arg" => slot_name},
            "receiver_slot_names" => [slot_name]
          })

        refute wm["isError"], "write_matcher for #{slot_name} failed: #{inspect(wm)}"
        assert is_integer(wm["structuredContent"]["id"])
      end
    end
  end
end
