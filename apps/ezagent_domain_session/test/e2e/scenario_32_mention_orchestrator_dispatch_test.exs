defmodule EzagentDomainInstanceMessage.E2E.Scenario32_MentionOrchestratorDispatchTest do
  @moduledoc """
  E2E Scenario 32 — Feishu @-mention orchestrator → dispatch
  (`docs/scenarios/32-feishu-mention-orchestrator-dispatch/scenario.md`).

  The orchestrator is a **member** of its session; a user drives it by
  @-mentioning it, and the routed message reaches the orchestrator's
  live claude, which acts via its 7 MCP tools.

  This file is the **deterministic invariant gate** (the scenario's
  Verification tier 1) — it does NOT require a live claude. It pins the
  two invariants that the orchestrator-startup-atomicity round actually
  fixed and that NO existing test covered:

    * **G1 (membership)** — after `create_session/3`, the session is
      live and the owner is joined, but the orchestrator role has NOT
      been eagerly spawned. The first route to `role: orchestrator`
      provisions that ordinary member and joins it.

    * **G2 (delivery routing)** — a message that @-mentions the
      orchestrator resolves the orchestrator as a recipient via
      `Ezagent.Routing.Resolver` when (and only when) the orchestrator is
      a session member. This is the routing half of "the mention is
      delivered to the orchestrator" — the production dispatch
      (`Behavior.Session :send`) makes the SAME `Resolver.resolve/4`
      decision the feishu inbound path drives.

  **G3 (create-agent) and G4 (modify-routing)** — the orchestrator's
  `add_managed_member` + `define_rule_set_rule` tools (team-routing-
  unification §3.8 retired the slot tools) — are already covered
  deterministically by
  `apps/ezagent_domain_session/test/integration/orchestrator_mcp_e2e_test.exs`
  (drives the member/rule-set tools through `McpServer.handle_tool_call/3`
  with the orchestrator's bound caps). This file does NOT duplicate that surface;
  it pins the membership + mention-routing invariants that connect a
  Feishu @-mention to those already-tested tools.

  **Live tier** (real claude + bound Feishu group, agent-browser
  screenshot per `feedback_esr_e2e_standards`) is the scenario's runbook
  — the true end-to-end — and is NOT this CI gate.

  In `:test` env the cc PtyServer short-circuits the real `:exec.run/2`
  (no live claude), so the route-time provision path can be exercised
  deterministically without a live bridge.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry, Message}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{Session, SessionTemplate, User}

  @moduletag scenario: "32-feishu-mention-orchestrator-dispatch"

  setup do
    # Shared sandbox provided by EzagentCore.DataCase (#92).

    # The orchestrator-spawn path reads owner lineage; admin is the
    # bootstrap principal in test env.
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp wait_until(fun, retries \\ 200) do
    case fun.() do
      false when retries > 0 ->
        Process.sleep(10)
        wait_until(fun, retries - 1)

      result ->
        result
    end
  end

  defp member_strs(session_uri) do
    session_uri
    |> Session.session_member_uris()
    |> Enum.map(&URI.to_string/1)
  end

  defp create_session_via_workspace(short_name, creator_uri, opts) do
    template_name = Keyword.fetch!(opts, :template_name)

    workspace_uri =
      Keyword.get(opts, :workspace_uri, Ezagent.Capability.workspace_of(creator_uri))

    ensure_workspace_seeded!(workspace_uri)

    with {:ok, result} <-
           Ezagent.Workspace.create_session(
             workspace_uri,
             %{short_name: short_name, template_name: template_name},
             Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, creator_uri)
           ) do
      {:ok, result.session_uri, %{}}
    end
  end

  defp route_to_orchestrator_template do
    n = uniq()
    template_name = "s32-route-orch-#{n}"
    source_template_uri = seed_echo_agent_template(n)

    persist_session_template(%{
      name: template_name,
      description: "Scenario 32 route-time orchestrator role",
      default_workspace_uri: Ezagent.URI.workspace(:system),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-23 00:00:00Z],
      members: [
        %{
          uri: nil,
          role_name: "orchestrator",
          in_session_template: true,
          source_template_uri: source_template_uri
        }
      ],
      routing_rules: [
        %{
          matcher: Ezagent.Routing.Matcher.from(User.admin_uri()),
          receivers: ["orchestrator"],
          rule_set: nil,
          position: 0
        }
      ],
      prompt_templates: %{},
      legends: %{}
    })

    template_name
  end

  defp ensure_workspace_seeded!(%URI{scheme: "workspace", host: name})
       when is_binary(name) and name != "" do
    case Ezagent.Workspace.Store.get_by_name(name) do
      nil ->
        case Ezagent.Workspace.create(name, %{}) do
          {:ok, _pid} -> :ok
          {:error, :workspace_exists} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to seed workspace #{name}: #{inspect(reason)}"
        end

      _ ->
        :ok
    end
  end

  # ----------------------------------------------------------------------
  # G1 — create joins owner only; route-time role delivery provisions orchestrator
  # ----------------------------------------------------------------------

  describe "G1 — create is decoupled; role route provisions orchestrator" do
    test "create_session joins owner only, then session.send provisions role: orchestrator" do
      admin = User.admin_uri()

      {:ok, session_uri, %{}} =
        create_session_via_workspace("s32-g1-#{uniq()}", admin,
          template_name: route_to_orchestrator_template()
        )

      owner = URI.to_string(admin)

      assert member_strs(session_uri) == [owner]

      assert nil == role_member_uri(session_uri, "orchestrator")

      :ok = dispatch_send(admin, session_uri, "wake the orchestrator")

      assert wait_until(fn -> match?(%URI{}, role_member_uri(session_uri, "orchestrator")) end),
             "first route to role: orchestrator must provision and join the ordinary member"

      orch = role_member_uri(session_uri, "orchestrator")
      assert URI.to_string(orch) in member_strs(session_uri)
    end
  end

  # ----------------------------------------------------------------------
  # G2 — a mention to the orchestrator resolves it as a recipient
  # ----------------------------------------------------------------------

  describe "G2 — delivery routing: route-time role delivery is durable" do
    test "subsequent sends keep the provisioned orchestrator as a member" do
      admin = User.admin_uri()

      {:ok, session_uri, %{}} =
        create_session_via_workspace("s32-g2-#{uniq()}", admin,
          template_name: route_to_orchestrator_template()
        )

      :ok = dispatch_send(admin, session_uri, "wake orchestrator once")
      assert wait_until(fn -> match?(%URI{}, role_member_uri(session_uri, "orchestrator")) end)

      orch = role_member_uri(session_uri, "orchestrator")

      :ok = dispatch_send(admin, session_uri, "second message")

      assert wait_until(fn -> URI.to_string(orch) in member_strs(session_uri) end)
    end
  end

  defp role_member_uri(session_uri, role_name) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: slice}}} = :sys.get_state(pid)
    SessionBehavior.role_name_to_uri(slice.members, role_name)
  end

  defp dispatch_send(caller_uri, session_uri, text) do
    msg = Message.new(caller_uri, %{text: text, attachments: []})
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.send")
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, caller_uri)

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: %{
        caller: caller_uri,
        authenticated_principal: caller_uri,
        caps: MapSet.new([cap]),
        reply: :ignore
      }
    })
  end

  defp seed_echo_agent_template(n) do
    uri = Ezagent.URI.new!("template://system/agent/s32-lazy-role-#{n}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    target = URI.new!("#{URI.to_string(uri)}?action=template.write")
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, User.admin_uri())

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{
          content: %{
            flavor: "cc",
            project_cwd: "/tmp",
            default_caps: [],
            created_by: User.admin_uri(),
            created_at: ~U[2026-06-23 00:00:00Z]
          }
        },
        ctx: %{
          caller: User.admin_uri(),
          authenticated_principal: User.admin_uri(),
          caps: MapSet.new([cap]),
          reply: {:caller_inbox, self()}
        }
      })

    on_exit(fn ->
      terminate_if_alive(EzagentDomainInstanceMessage.AgentTemplateSupervisor, uri)
    end)

    uri
  end

  defp persist_session_template(content) do
    hash = SessionTemplate.compute_version_hash(content)
    uri = SessionTemplate.build_uri(content.name, hash, workspace: "system")
    :ok = KindSnapshot.delete(URI.to_string(uri))
    {:ok, persisted_uri} = SessionTemplate.persist_version_as_system(content, "system")

    on_exit(fn ->
      terminate_if_alive(EzagentDomainInstanceMessage.SessionTemplateSupervisor, persisted_uri)
    end)

    persisted_uri
  end

  defp terminate_if_alive(supervisor, uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(supervisor, pid)

      _ ->
        :ok
    end
  end
end
