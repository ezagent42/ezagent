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

    * **G1 (membership)** — after the atomic `create_session/3`,
      `Ezagent.Entity.Session.session_member_uris/1` includes BOTH the
      owner AND the orchestrator URI. This is the exact regression the
      scenario gates: pre-fix `members` was empty (the readiness-gate
      timeout rolled the session back before the step-8 join), so the
      orchestrator — though registered — received no session messages.
      Per `feedback_completion_requires_invariant_test`, THIS test is
      the architectural gate: it fails when the goal (orchestrator is a
      reachable member) is unmet.

    * **G2 (delivery routing)** — a message that @-mentions the
      orchestrator resolves the orchestrator as a recipient via
      `Ezagent.Routing.Resolver` when (and only when) the orchestrator is
      a session member. This is the routing half of "the mention is
      delivered to the orchestrator" — the production dispatch
      (`Behavior.Chat :send`) makes the SAME `Resolver.resolve/4`
      decision the feishu inbound path drives.

  **G3 (create-agent) and G4 (modify-routing)** — the orchestrator's
  `add_managed_member` + `define_rule_set_rule` tools (team-routing-
  unification §3.8 retired the slot tools) — are already covered
  deterministically by
  `apps/ezagent_domain_instance_message/test/integration/orchestrator_mcp_e2e_test.exs`
  (drives the member/rule-set tools through `McpServer.handle_tool_call/3`
  with the orchestrator's bound caps). This file does NOT duplicate that surface;
  it pins the membership + mention-routing invariants that connect a
  Feishu @-mention to those already-tested tools.

  **Live tier** (real claude + bound Feishu group, agent-browser
  screenshot per `feedback_esr_e2e_standards`) is the scenario's runbook
  — the true end-to-end — and is NOT this CI gate.

  In `:test` env the cc PtyServer short-circuits the real `:exec.run/2`
  (no live claude) and the readiness gate is compile-time bypassed
  (`@compile_env == :test`), so `create_session/3` runs the full atomic
  flow — including the step-8 member join — without a subprocess.
  """

  use ExUnit.Case, async: false

  alias Ezagent.{Message, RoutingRegistry, Routing.Matcher, Routing.Resolver}
  alias Ezagent.Entity.{Session, User}

  @moduletag scenario: "32-feishu-mention-orchestrator-dispatch"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

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

  defp workspace_of(session_uri) do
    {:ok, ws} = Ezagent.WorkspaceRegistry.lookup(session_uri)
    ws
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
             %{caller: creator_uri, caps: Ezagent.SystemPrincipal.caps("system://bootstrap")}
           ) do
      {:ok, result.session_uri,
       %{
         orchestrator_uri: result.orchestrator_uri,
         orchestrator_status: result.orchestrator_status,
         orchestrator_error: result.orchestrator_error
       }}
    end
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
  # G1 — orchestrator is a session member after create_session/3
  # ----------------------------------------------------------------------

  describe "G1 — membership: orchestrator + owner are members after create_session/3" do
    test "session_member_uris includes BOTH the owner and the orchestrator" do
      admin = User.admin_uri()

      {:ok, session_uri, meta} =
        create_session_via_workspace("s32-g1-#{uniq()}", admin, template_name: "default")

      # The orchestrator reached :ready (gate bypassed in :test) and its
      # URI is populated — precondition for it being a member.
      assert meta.orchestrator_status == :ready,
             "orchestrator must reach :ready, got #{inspect(meta.orchestrator_status)} " <>
               "(error=#{inspect(meta.orchestrator_error)})"

      orch = URI.to_string(meta.orchestrator_uri)
      owner = URI.to_string(admin)

      # The step-8 join ([owner, orchestrator]) is async; wait for both.
      assert wait_until(fn ->
               members = member_strs(session_uri)
               owner in members and orch in members
             end),
             "after create_session, session_member_uris MUST include BOTH the owner " <>
               "(#{owner}) AND the orchestrator (#{orch}) — the 'empty members' regression. " <>
               "Got: #{inspect(member_strs(session_uri))}"
    end

    test "the orchestrator member URI equals meta.orchestrator_uri (no drift)" do
      admin = User.admin_uri()

      {:ok, session_uri, meta} =
        create_session_via_workspace("s32-g1b-#{uniq()}", admin, template_name: "default")

      orch = URI.to_string(meta.orchestrator_uri)

      assert wait_until(fn -> orch in member_strs(session_uri) end),
             "the orchestrator that joined as a member MUST be exactly the one in " <>
               "meta.orchestrator_uri (#{orch}) — divergent member vs registered URI " <>
               "would silently mis-bind mention routing. Got: #{inspect(member_strs(session_uri))}"
    end
  end

  # ----------------------------------------------------------------------
  # G2 — a mention to the orchestrator resolves it as a recipient
  # ----------------------------------------------------------------------

  describe "G2 — delivery routing: mention to the orchestrator resolves it as a recipient" do
    setup do
      table = String.to_atom("s32_routing_#{uniq()}")
      :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

      :ok =
        RoutingRegistry.put(
          table,
          Matcher.always(),
          %{
            receivers: [Resolver.session_users_token(), Resolver.mentions_token()],
            applies_to_users: [],
            workspace_uri: nil
          }
        )

      original = Application.get_env(:ezagent_core, :routing_tables)
      Application.put_env(:ezagent_core, :routing_tables, [table])

      on_exit(fn ->
        if original do
          Application.put_env(:ezagent_core, :routing_tables, original)
        else
          Application.delete_env(:ezagent_core, :routing_tables)
        end
      end)

      :ok
    end

    defp build_msg(sender, text, mentions) do
      %Message{
        id: "s32-#{System.unique_integer([:positive])}",
        sender: sender,
        body: %{text: text, attachments: []},
        mentions: mentions,
        ref_id: nil,
        inserted_at: ~U[2026-05-31 00:00:00.000000Z]
      }
    end

    test "mentioning the orchestrator (a member) delivers to it" do
      admin = User.admin_uri()

      {:ok, session_uri, meta} =
        create_session_via_workspace("s32-g2-#{uniq()}", admin, template_name: "default")

      orch_uri = meta.orchestrator_uri
      orch = URI.to_string(orch_uri)

      assert wait_until(fn -> orch in member_strs(session_uri) end)

      # The real member list as create_session populated it.
      members = Session.session_member_uris(session_uri)
      workspace_uri = workspace_of(session_uri)

      msg = build_msg(admin, "@orch please create a worker", [orch_uri])

      recipients =
        Resolver.resolve(msg, session_uri, members, workspace_uri: workspace_uri)
        |> Enum.map(&URI.to_string/1)

      assert orch in recipients,
             "an @-mention of the orchestrator MUST route to it (it is a member) — " <>
               "this is the routing half of G2 delivery. Got: #{inspect(recipients)}"
    end

    test "a NON-mention message does NOT fan out to the orchestrator (mention-gated)" do
      admin = User.admin_uri()

      {:ok, session_uri, meta} =
        create_session_via_workspace("s32-g2b-#{uniq()}", admin, template_name: "default")

      orch = URI.to_string(meta.orchestrator_uri)
      assert wait_until(fn -> orch in member_strs(session_uri) end)

      members = Session.session_member_uris(session_uri)
      workspace_uri = workspace_of(session_uri)

      # No mention → the orchestrator (an Agent Kind) must NOT receive.
      msg = build_msg(admin, "just chatting, no mention", [])

      recipients =
        Resolver.resolve(msg, session_uri, members, workspace_uri: workspace_uri)
        |> Enum.map(&URI.to_string/1)

      refute orch in recipients,
             "without an @-mention the orchestrator MUST NOT receive — mention-gated " <>
               "routing (agents only via $mentions). Got: #{inspect(recipients)}"
    end
  end
end
