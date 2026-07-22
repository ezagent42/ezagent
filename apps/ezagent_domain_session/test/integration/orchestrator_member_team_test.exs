defmodule EzagentDomainInstanceMessage.Integration.OrchestratorMemberTeamTest do
  @moduledoc """
  team-routing-unification §3.8 (PR-8) — GATE (a), the HEADLINE test:
  **the orchestrator builds a team via MEMBERS + RULE-SETS (NOT slots).**

  The slot tools (`add_agent_slot` / `remove_agent_slot` /
  `update_agent_template` / `write_matcher`) are retired. The orchestrator
  now builds a relay team the same way `create_session/3` materialization
  does (PR-7), but ONE LIVE CALL AT A TIME, through the rewritten
  `Ezagent.Orchestrator.Tools` surface:

    * `add_managed_member/4` — spawn a member from a source AgentTemplate +
      join it with a `role_name` + `in_session_template` facet (the PR-7
      `Agent.spawn_fresh` + faceted `chat.join` path);
    * `define_prompt_template/3` — install a named prompt template;
    * `define_rule_set_rule/3` — a single-receiver rule targeting a member
      BY ROLE_NAME, with a `prompt_template_ref`;
    * `define_legend/5` — front the rule-set with a `@legend` handle.

  We then prove the built team materializes + ROUTES through the SAME
  PR-2/PR-4/PR-6 delivery seam (`resolve_with_ctx` → `render_for_delivery`)
  — with NO baton token computed by any model, the relay is expressible
  PURELY as `{:from, role_name→uri}` rules + a legend trigger.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Invocation, KindRegistry, Message, RoutingRegistry}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Entity.{Agent, Session, User}
  alias Ezagent.Orchestrator.Tools
  alias Ezagent.Routing.{Matcher, Resolver}
  alias Ezagent.Socialware.DefinitionRegistry
  import Ezagent.Test.CapHelper, only: [ensure_workspace_kind!: 1, signed_action_cap!: 2]

  defp uniq, do: System.unique_integer([:positive])

  @workspace_uri URI.new!("workspace://system")

  setup do
    # Tools install rule-set rows into the process-global RoutingRegistry.
    # DB rows roll back with the sandbox; reload the (now-empty) DB into the
    # ETS table on exit so a built rule doesn't leak into the next test.
    on_exit(fn ->
      table = Resolver.default_routing_table()

      try do
        Ezagent.Routing.RuleStore.load_into_registry(table)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  defp chat_slice(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: slice}}} = :sys.get_state(pid)
    slice
  end

  # Persist a minimal echo-flavor AgentTemplate Kind to spawn members from.
  defp seed_agent_template(n) do
    name = "pr8-seed-#{n}"
    uri = Ezagent.URI.new!("template://system/agent/#{name}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    target = URI.new!("#{URI.to_string(uri)}?action=template.write")

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
            created_at: ~U[2026-06-01 00:00:00Z]
          }
        },
        ctx: %{
          caller: User.admin_uri(),
          authenticated_principal: User.admin_uri(),
          caps: MapSet.new([signed_action_cap!(target, User.admin_uri())]),
          reply: {:caller_inbox, self()}
        }
      })

    on_exit(fn -> terminate_child(EzagentDomainInstanceMessage.AgentTemplateSupervisor, uri) end)
    uri
  end

  defp terminate_child(sup, uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} ->
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(sup, pid)

      :error ->
        :ok
    end
  end

  # Build the orchestrator's bound MCP-server context directly — the same
  # fixture pattern the slot-era orchestrator e2e used (orchestrator_mcp_e2e):
  # a plainly-spawned Session + orchestrator Agent + the orchestrator's
  # delegated caps (#1 within_session, #2 spawned_by, #3/#4 template). No
  # create_session round-trip (which would materialize a template team) — we
  # test the LIVE tool calls building a team incrementally.
  defp orchestrated_session(n) do
    session_uri = Ezagent.URI.session("system", "generic", "pr8-team-#{n}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)

    on_exit(fn ->
      terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, session_uri)
    end)

    orchestrator_uri = Ezagent.URI.new!("entity://system/agent/cc_orch-#{n}")
    :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")

    on_exit(fn ->
      Ezagent.AgentFlavorAttributes.delete(orchestrator_uri)
    end)

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)

    ensure_workspace_kind!(@workspace_uri)

    :ok =
      Ezagent.Entity.Session.Orchestrator.Caps.grant_orchestrator_scoped_caps(
        orchestrator_uri,
        session_uri,
        User.admin_uri()
      )

    caps = orchestrator_uri |> Ezagent.EntityCaps.load() |> MapSet.new()

    # PR-8 (transport #53): `Tools` is now driven directly with the
    # orchestrator's caller `opts` — the exact context the session-side
    # `Ezagent.ActionSet.OrchestratorTools` action reconstructs. (The cc
    # `McpServer` value-form / `tool_opts/1` helper is gone — it is a thin
    # transport that DISPATCHES into this op layer.)
    mcp = [
      caller: orchestrator_uri,
      authenticated_principal: orchestrator_uri,
      caps: caps,
      session_uri: session_uri,
      workspace_uri: @workspace_uri,
      owner: orchestrator_uri,
      parent_template_uri: nil
    ]

    {mcp, session_uri, @workspace_uri, orchestrator_uri}
  end

  test "orchestrator builds a relay team via members + rule-sets + legend, and it routes (NO baton)" do
    n = uniq()
    source_template_uri = seed_agent_template(n)
    role_name = "relay-cc-#{n}"
    legend_name = "传话游戏-#{n}"
    tpl_ref = "telephone_hop_#{n}"
    rule_set = "telephone-#{n}"

    {mcp, session_uri, workspace_uri, _orch} = orchestrated_session(n)

    # 1) add a managed member spawned from the source AgentTemplate ----------
    assert {:ok, member_uri} =
             Tools.add_managed_member(
               source_template_uri,
               role_name,
               true,
               mcp
             )

    assert Ezagent.URI.type?(member_uri, :agent)

    on_exit(fn -> terminate_child(EzagentDomainInstanceMessage.AgentSupervisor, member_uri) end)

    # The member appears with its role_name + the in_session_template facet +
    # the spawn-source facet (so a future respawn can rebuild it).
    slice = chat_slice(session_uri)
    assert SessionBehavior.role_name_to_uri(slice.members, role_name) == member_uri

    assert %{online: true, role_name: ^role_name, in_session_template: true} =
             slice.members[member_uri]

    assert slice.members[member_uri].source_template_uri == source_template_uri

    # 2) define a named prompt template --------------------------------------
    assert {:ok, _} =
             Tools.define_prompt_template(
               tpl_ref,
               "接龙：{body}（by {sender}）",
               mcp
             )

    # 3) define a rule-set rule targeting the member BY ROLE_NAME ------------
    assert {:ok, %{id: _}} =
             Tools.define_rule_set_rule(
               Matcher.mention(legend_name),
               role_name,
               [rule_set: rule_set, position: 0, prompt_template_ref: tpl_ref] ++
                 mcp
             )

    # 4) front the rule-set with a legend ------------------------------------
    assert {:ok, _} =
             Tools.define_legend(
               legend_name,
               [role_name],
               rule_set,
               true,
               mcp
             )

    # ── the team is built. Now prove it ROUTES (PR-2/PR-4/PR-6 seam). ──────
    slice = chat_slice(session_uri)
    assert slice.prompt_templates[tpl_ref] == "接龙：{body}（by {sender}）"

    assert {:ok, %{bound_rule_set: ^rule_set}} =
             SessionBehavior.resolve_legend(slice, legend_name)

    table = Resolver.default_routing_table()
    rows = RoutingRegistry.list_all(table)

    assert Enum.any?(rows, fn
             {{:mention, ^legend_name}, %{rule_set: ^rule_set, prompt_template_ref: ^tpl_ref} = v} ->
               URI.to_string(member_uri) in v.receivers

             _ ->
               false
           end),
           "expected the rule-set entry rule routing @#{legend_name} → #{URI.to_string(member_uri)}; got: #{inspect(rows)}"

    # The relay resolves through the rule-set to the member — purely from a
    # {:mention, legend} entry rule (NO model-computed baton).
    operator = User.admin_uri()

    msg =
      Message.new(operator, %{text: "山顶的雪化了", attachments: []}, legend_triggers: [legend_name])

    pairs =
      Resolver.resolve_with_ctx(msg, session_uri, Map.keys(slice.members),
        workspace_uri: workspace_uri
      )

    assert {^member_uri, ctx} =
             Enum.find(pairs, fn {u, _} -> URI.to_string(u) == URI.to_string(member_uri) end),
           "legend trigger must route to the managed member; got #{inspect(pairs)}"

    assert ctx.prompt_template_ref == tpl_ref

    delivered = SessionBehavior.render_for_delivery(msg, ctx, slice.prompt_templates, session_uri)
    assert delivered.body.text == "接龙：山顶的雪化了（by #{URI.to_string(operator)}）"
  end

  # ── codex PR-8 fix regressions ─────────────────────────────────────────

  test "codex B1 — an orchestrator-defined rule is stamped created_by=session_uri and round-trips through save_template_as" do
    n = uniq()
    src = seed_agent_template(n)
    role = "relay-cc-#{n}"
    rule_set = "telephone-#{n}"

    {mcp, session_uri, _ws, orch} = orchestrated_session(n)

    {:ok, member_uri} = Tools.add_managed_member(src, role, true, mcp)
    on_exit(fn -> terminate_child(EzagentDomainInstanceMessage.AgentSupervisor, member_uri) end)

    assert {:ok, %{id: rule_id}} =
             Tools.define_rule_set_rule(
               Matcher.mention("legend-#{n}"),
               role,
               [rule_set: rule_set, position: 0] ++ mcp
             )

    # The persisted rule carries the per-session identity the snapshot keys on
    # (pre-fix it was nil → silently dropped from the template).
    table = Resolver.default_routing_table()
    row = Enum.find(Ezagent.Routing.RuleStore.list(table), &(&1.id == rule_id))
    assert row, "the defined rule must be persisted"

    assert row.created_by == URI.to_string(session_uri),
           "B1: orchestrator-defined rule must be stamped created_by=session_uri " <>
             "(got #{inspect(row.created_by)}); otherwise session_rule_set_rules drops it"

    # And it round-trips into the saved template's installed Socialware definition.
    caps = mcp[:caps]

    save_opts = [
      caller: orch,
      authenticated_principal: orch,
      caps: caps,
      session_uri: session_uri,
      workspace_uri: @workspace_uri
    ]

    template_name = "pr8-b1-saved-#{n}"

    assert {:ok, %URI{} = new_template_uri} = Tools.save_template_as(template_name, save_opts)

    {:ok, content} = Ezagent.Entity.Session.read_template_content(new_template_uri)
    assert content.installs == [template_name]
    refute Map.has_key?(content, :routing_rules)
    refute Map.has_key?(content, "routing_rules")

    assert {:ok, definition, _object} = DefinitionRegistry.lookup(@workspace_uri, template_name)
    rules = definition.routing_rules

    assert Enum.any?(rules, fn r ->
             (Map.get(r, :rule_set) || Map.get(r, "rule_set")) == rule_set
           end),
           "B1: the orchestrator-defined rule-set rule must be captured in the saved " <>
             "template's socialware definition routing_rules; got #{inspect(rules)}"
  end

  test "codex M2 — an unauthorized add_managed_member does NOT spawn a worker" do
    n = uniq()
    src = seed_agent_template(n)
    role = "relay-cc-#{n}"

    {mcp, session_uri, _ws, _orch} = orchestrated_session(n)

    # Strip the concrete Session.join cap — the caller is now unauthorized.
    no_session_caps =
      mcp[:caps]
      |> Enum.reject(fn
        %Capability{kind: :session, behavior: SessionBehavior, instance: %URI{} = target} = cap ->
          Ezagent.Capability.action_of(cap) == :join and
            Ezagent.URI.stable_key(target) == Ezagent.URI.stable_key(session_uri)

        _ ->
          false
      end)
      |> MapSet.new()

    opts = Keyword.put(mcp, :caps, no_session_caps)

    assert {:error, :unauthorized} = Tools.add_managed_member(src, role, true, opts)

    # No member was spawned + joined: the session's members slice has no
    # member holding `role` (the preflight fails BEFORE spawn_member runs).
    slice = chat_slice(session_uri)

    assert SessionBehavior.role_name_to_uri(slice.members, role) == nil,
           "M2: an unauthorized add_managed_member must not leave a spawned/joined member; " <>
             "members=#{inspect(Map.keys(slice.members))}"
  end

  test "the relay chain is expressible as {:from, role→uri} rules with NO baton token" do
    # A two-hop chain (cc → codex): the SECOND hop fires on {:from, cc_uri},
    # routes to codex. The model emits NOTHING — the routing table IS the
    # baton. We assert the chain topology deterministically at the Resolver
    # level (no live agents needed).
    n = uniq()
    src = seed_agent_template(n)
    cc_role = "relay-cc-#{n}"
    codex_role = "relay-codex-#{n}"
    rule_set = "telephone-#{n}"

    {mcp, session_uri, workspace_uri, _orch} = orchestrated_session(n)

    {:ok, cc_uri} = Tools.add_managed_member(src, cc_role, true, mcp)
    {:ok, codex_uri} = Tools.add_managed_member(src, codex_role, true, mcp)
    on_exit(fn -> terminate_child(EzagentDomainInstanceMessage.AgentSupervisor, cc_uri) end)
    on_exit(fn -> terminate_child(EzagentDomainInstanceMessage.AgentSupervisor, codex_uri) end)

    # Hop rule: from(cc) → codex. The matcher names the cc member URI; the
    # receiver is targeted by role_name (resolved to codex's URI).
    assert {:ok, %{id: _}} =
             Tools.define_rule_set_rule(
               Matcher.from(cc_uri),
               codex_role,
               [rule_set: rule_set, position: 1] ++ mcp
             )

    slice = chat_slice(session_uri)

    # A message SENT BY cc resolves (purely from the {:from, cc} rule) to
    # codex — the baton lives in the table, not the message body.
    msg = Message.new(cc_uri, %{text: "下一句", attachments: []})

    pairs =
      Resolver.resolve_with_ctx(msg, session_uri, Map.keys(slice.members),
        workspace_uri: workspace_uri
      )

    assert Enum.any?(pairs, fn {u, _} -> URI.to_string(u) == URI.to_string(codex_uri) end),
           "the {:from, cc}→codex hop must route to codex with NO baton; got #{inspect(pairs)}"
  end
end
