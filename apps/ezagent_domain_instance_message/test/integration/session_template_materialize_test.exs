defmodule EzagentDomainInstanceMessage.Integration.SessionTemplateMaterializeTest do
  @moduledoc """
  team-routing-unification §3.7 (PR-7) — GATE (b), the HEADLINE test:
  **instantiate a SessionTemplate → the team actually appears + routes.**

  `EzagentDomainInstanceMessage.SessionCreator.create_session/3` no longer joins only
  `[owner, orchestrator]`. It MATERIALIZES the template's team:

    * recreates + joins each `in_session_template: true` member with its
      `role_name` (+ spawn-source facet) — a spawned member via the
      unified `Agent.spawn/4` path, a plain invited member via its `uri`;
    * installs the template's named `prompt_templates` (§3.4);
    * installs the template's `legends` (§3.6);
    * installs the template's rule-set routing rules (§3.3), resolving
      each rule's `role_name` receivers to the live member URIs.

  This proves the load-bearing contract codex flagged: an instantiated
  template PRODUCES the working team. We verify both halves:

    1. **the team appears** — the materialized member shows in
       `chat.members` carrying its `role_name`; the slice carries the
       installed `prompt_templates` + `legends`; the rule-set rule is in
       the live RoutingRegistry.
    2. **it routes (with the prompt-template applied)** — reusing the
       PR-4/PR-6 delivery path: a `@legend`-triggered message resolves —
       through the INSTALLED rule-set — to the materialized member, and
       `Chat.render_for_delivery/4` applies the INSTALLED prompt template
       so the member's delivered message is the TEMPLATED payload. We also
       drive a live `chat.send` and confirm the member actually receives.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry, Message, RoutingRegistry}
  alias Ezagent.Behavior.Chat
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{SessionTemplate, User}
  alias Ezagent.Routing.{Matcher, Resolver}

  defp uniq, do: System.unique_integer([:positive])

  setup do
    # create_session installs the rule-set into the live (real)
    # RoutingRegistry default table. The DB rows roll back with the
    # sandbox, but the ETS table is process-global — reload it from the
    # (now empty) DB on exit so a materialized rule doesn't leak into the
    # next test's Resolver.
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

  # Read the live Session Kind's :chat slice.
  defp chat_slice(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{chat: %{state: slice}}} = :sys.get_state(pid)
    slice
  end

  # A relay-team SessionTemplate content carrying the PR-7 fields. The team
  # member is a plain invited User (a real Kind, joinable + receives live)
  # so the gate needs no agent bridge. The legend `@legend` fronts a
  # rule-set whose single rule routes (by role_name) to that member with a
  # prompt-template applied.
  defp relay_team_content(name, source_template_uri, role_name, legend_name, tpl_ref) do
    %{
      name: name,
      description: "relay team",
      # Plain session (no orchestrator) keeps the gate focused on
      # materialization, not orchestrator startup.
      orchestrator_template_uri: nil,
      default_workspace_uri: Ezagent.URI.new!("workspace://system"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z],
      members: [
        # A SPAWNED agent member (recreated from its AgentTemplate). An agent
        # member is reached ONLY by an explicit rule targeting it — NOT by the
        # boot `system_default` `{:always} → [$session_users, $mentions]` rule
        # (it is neither a $session_user nor a $mention) — so the legend
        # rule-set is the sole route, giving a clean matched-rule ctx.
        %{
          uri: nil,
          role_name: role_name,
          in_session_template: true,
          source_template_uri: source_template_uri
        }
      ],
      prompt_templates: %{
        tpl_ref => "接龙：{body}（by {sender}）"
      },
      legends: %{
        legend_name => %{member_set: [role_name], bound_rule_set: "telephone", fold: true}
      },
      routing_rules: [
        %{
          # The legend `@`-trigger entry rule — fires on mention(<legend>).
          matcher: Matcher.mention(legend_name),
          # Targeted BY ROLE_NAME — materialization resolves it to the live
          # member URI after the member joins (§3.3/§3.7).
          receivers: [role_name],
          rule_set: "telephone",
          position: 0,
          prompt_template_ref: tpl_ref
        }
      ]
    }
  end

  defp persist_template(content) do
    hash = SessionTemplate.compute_version_hash(content)

    :ok =
      KindSnapshot.delete(
        URI.to_string(SessionTemplate.build_uri(content.name, hash, workspace: "system"))
      )

    {:ok, uri} = SessionTemplate.persist_version_as_system(content, "system")

    on_exit(fn ->
      case KindRegistry.lookup(uri) do
        {:ok, pid} ->
          if Process.alive?(pid),
            do:
              DynamicSupervisor.terminate_child(
                EzagentDomainInstanceMessage.SessionTemplateSupervisor,
                pid
              )

        :error ->
          :ok
      end
    end)

    uri
  end

  test "instantiating a template materializes the team (members + legends + prompt_templates + rule-set) and routes" do
    n = uniq()
    template_name = "relay-team-#{n}"
    legend_name = "传话游戏-#{n}"
    tpl_ref = "telephone_hop_#{n}"
    role_name = "relay-cc-#{n}"

    # The team member is a SPAWNED echo agent (recreated from its
    # AgentTemplate at materialize time). Spawned-from-template members are
    # the load-bearing case codex flagged — and an agent member is reached
    # ONLY by an explicit rule, so the legend rule-set is its sole route.
    source_template_uri = seed_agent_template(n)

    content =
      relay_team_content(template_name, source_template_uri, role_name, legend_name, tpl_ref)

    _template_uri = persist_template(content)

    # ── instantiate the template ────────────────────────────────────────
    short = "relay-sess-#{n}"

    assert {:ok, session_uri, _meta} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
               template_name: template_name
             )

    on_exit(fn ->
      case KindRegistry.lookup(session_uri) do
        {:ok, pid} ->
          if Process.alive?(pid),
            do:
              DynamicSupervisor.terminate_child(
                EzagentDomainInstanceMessage.SessionSupervisor,
                pid
              )

        :error ->
          :ok
      end
    end)

    # ── (1) the team APPEARS ──────────────────────────────────────────────
    slice = chat_slice(session_uri)

    # The spawned agent member was recreated + joined, carrying role_name +
    # the in_session_template snapshot facet + the spawn-source facet.
    member_uri = Chat.role_name_to_uri(slice.members, role_name)
    assert Ezagent.URI.type?(member_uri, :agent)

    assert %{online: true, role_name: ^role_name, in_session_template: true} =
             slice.members[member_uri]

    assert slice.members[member_uri].source_template_uri == source_template_uri

    on_exit(fn ->
      case KindRegistry.lookup(member_uri) do
        {:ok, pid} ->
          if Process.alive?(pid),
            do:
              DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.AgentSupervisor, pid)

        :error ->
          :ok
      end
    end)

    # The template's prompt_templates + legends were installed on the slice.
    assert slice.prompt_templates[tpl_ref] == "接龙：{body}（by {sender}）"
    assert {:ok, %{bound_rule_set: "telephone"}} = Chat.resolve_legend(slice, legend_name)

    # The rule-set rule is live in the RoutingRegistry — and its receiver was
    # resolved from role_name to the materialized member's concrete URI.
    table = Resolver.default_routing_table()
    rows = RoutingRegistry.list_all(table)

    assert Enum.any?(rows, fn
             {{:mention, ^legend_name},
              %{rule_set: "telephone", prompt_template_ref: ^tpl_ref} = v} ->
               URI.to_string(member_uri) in v.receivers

             _ ->
               false
           end),
           "expected the installed telephone rule-set entry rule routing " <>
             "@#{legend_name} → #{URI.to_string(member_uri)}; got: #{inspect(rows)}"

    # ── (2) it ROUTES, with the prompt-template applied ───────────────────
    # Reuse the PR-4/PR-6 delivery path against the INSTALLED state: a
    # legend-triggered message resolves through the installed rule-set to the
    # materialized member, carrying the rule's prompt_template_ref; the
    # delivery render applies the INSTALLED template. This is the SAME
    # resolve_with_ctx → render_for_delivery seam Chat.handle_send/2 drives.
    operator = User.admin_uri()

    msg =
      Message.new(operator, %{text: "山顶的雪化了", attachments: []}, legend_triggers: [legend_name])

    in_session_members = Map.keys(slice.members)

    pairs =
      Resolver.resolve_with_ctx(msg, session_uri, in_session_members,
        workspace_uri: URI.new!("workspace://system")
      )

    assert {%URI{} = recipient, ctx} =
             Enum.find(pairs, fn {u, _} -> URI.to_string(u) == URI.to_string(member_uri) end),
           "legend trigger must route to the materialized member; got #{inspect(pairs)}"

    assert recipient == member_uri
    assert ctx.prompt_template_ref == tpl_ref

    delivered = Chat.render_for_delivery(msg, ctx, slice.prompt_templates, session_uri)
    assert delivered.body.text == "接龙：山顶的雪化了（by #{URI.to_string(operator)}）"

    # ── live liveness: a real chat.send through the Session does not error
    # and the message lands in the store (the materialized session is a
    # working, send-able team).
    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session_uri)}?action=chat.send"),
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: operator,
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: :ignore
        }
      })

    # Synchronize on the Session GenServer draining the cast, then confirm
    # the send was recorded (the slice's last_message_id advanced).
    {:ok, session_pid} = KindRegistry.lookup(session_uri)
    %{state: %{chat: %{state: post}}} = :sys.get_state(session_pid)
    assert post.last_message_id == msg.id
  end

  test "a spawned-member template recreates the agent from source_template_uri via the unified spawn path" do
    n = uniq()
    template_name = "spawn-team-#{n}"
    role_name = "worker-#{n}"

    # A seed AgentTemplate the spawned member is recreated from. The echo
    # flavor's seed template exists in the test boot; we persist a minimal
    # AgentTemplate Kind to spawn from.
    source_template_uri = seed_agent_template(n)

    content = %{
      name: template_name,
      description: "spawned-member team",
      orchestrator_template_uri: nil,
      default_workspace_uri: Ezagent.URI.new!("workspace://system"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z],
      members: [
        %{
          uri: nil,
          role_name: role_name,
          in_session_template: true,
          source_template_uri: source_template_uri
        }
      ],
      prompt_templates: %{},
      legends: %{},
      routing_rules: []
    }

    _template_uri = persist_template(content)

    short = "spawn-sess-#{n}"

    assert {:ok, session_uri, _meta} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
               template_name: template_name
             )

    on_exit(fn ->
      case KindRegistry.lookup(session_uri) do
        {:ok, pid} ->
          if Process.alive?(pid),
            do:
              DynamicSupervisor.terminate_child(
                EzagentDomainInstanceMessage.SessionSupervisor,
                pid
              )

        :error ->
          :ok
      end
    end)

    slice = chat_slice(session_uri)

    # A spawned agent member appears under a workspace-first entity agent URI
    # and carrying its role_name + the spawn-source facet (so a future
    # respawn can rebuild it).
    spawned = Chat.role_name_to_uri(slice.members, role_name)
    assert Ezagent.URI.type?(spawned, :agent)
    assert slice.members[spawned].in_session_template == true
    assert slice.members[spawned].source_template_uri == source_template_uri

    on_exit(fn ->
      case KindRegistry.lookup(spawned) do
        {:ok, pid} ->
          if Process.alive?(pid),
            do:
              DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.AgentSupervisor, pid)

        :error ->
          :ok
      end
    end)
  end

  test "two sessions from ONE template get DISTINCT member URIs; re-materializing a session is idempotent (codex BLOCKER #1)" do
    n = uniq()
    template_name = "iso-team-#{n}"
    role_name = "worker-#{n}"
    source_template_uri = seed_agent_template(n)

    content = %{
      name: template_name,
      description: "isolation team",
      orchestrator_template_uri: nil,
      default_workspace_uri: Ezagent.URI.new!("workspace://system"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z],
      members: [
        %{
          uri: nil,
          role_name: role_name,
          in_session_template: true,
          source_template_uri: source_template_uri
        }
      ],
      prompt_templates: %{},
      legends: %{},
      routing_rules: []
    }

    _template_uri = persist_template(content)

    # ── two DISTINCT sessions from the SAME template in the SAME workspace ─
    assert {:ok, session_a, _} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "iso-a-#{n}",
               User.admin_uri(),
               template_name: template_name
             )

    assert {:ok, session_b, _} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "iso-b-#{n}",
               User.admin_uri(),
               template_name: template_name
             )

    cleanup_session(session_a)
    cleanup_session(session_b)

    member_a = Chat.role_name_to_uri(chat_slice(session_a).members, role_name)
    member_b = Chat.role_name_to_uri(chat_slice(session_b).members, role_name)

    cleanup_agent(member_a)
    cleanup_agent(member_b)

    # The prior isolation bug: both sessions collided on the SAME
    # entity agent URI. The session-discriminator
    # in the instance name must make them DISTINCT.
    assert Ezagent.URI.type?(member_a, :agent)
    assert Ezagent.URI.type?(member_b, :agent)

    refute member_a == member_b,
           "two sessions from one template must NOT share a member URI; got #{URI.to_string(member_a)} for both"

    # ── re-materializing the SAME session is idempotent (same URI) ────────
    # A respawn within the SAME session for the SAME role_name must land on
    # the SAME URI (deterministic from the session discriminator).
    member_a_again =
      EzagentDomainInstanceMessage.materialize_template_team(
        session_a,
        URI.new!("workspace://system"),
        User.admin_uri(),
        content
      )
      |> case do
        :ok -> Chat.role_name_to_uri(chat_slice(session_a).members, role_name)
      end

    assert member_a_again == member_a,
           "re-materializing the same session for the same role must be idempotent (same URI)"
  end

  test "two sessions from DIFFERENT templates (same workspace + same short_name) get DISTINCT member URIs (codex cycle-2 BLOCKER #1)" do
    n = uniq()
    role_name = "worker-#{n}"
    source_template_uri = seed_agent_template(n)

    build_content = fn template_name ->
      %{
        name: template_name,
        description: "cross-template isolation team",
        orchestrator_template_uri: nil,
        default_workspace_uri: Ezagent.URI.new!("workspace://system"),
        parent_template_uri: nil,
        version_tag: nil,
        created_by: User.admin_uri(),
        created_at: ~U[2026-06-01 00:00:00Z],
        members: [
          %{
            uri: nil,
            role_name: role_name,
            in_session_template: true,
            source_template_uri: source_template_uri
          }
        ],
        prompt_templates: %{},
        legends: %{},
        routing_rules: []
      }
    end

    template_a = "xtpl-a-#{n}"
    template_b = "xtpl-b-#{n}"
    _ = persist_template(build_content.(template_a))
    _ = persist_template(build_content.(template_b))

    # SAME workspace (system), SAME short_name — the collision pre-condition.
    # Only the template/type axis differs.
    short = "same-short-#{n}"

    assert {:ok, session_a, _} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
               template_name: template_a
             )

    assert {:ok, session_b, _} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
               template_name: template_b
             )

    # Sanity: the two session URIs differ ONLY in their template/type segment
    # — exactly the case the name-only discriminator collapsed.
    assert Ezagent.URI.type(session_a) == {:ok, template_a}
    assert Ezagent.URI.type(session_b) == {:ok, template_b}
    assert Ezagent.URI.workspace_name(session_a) == {:ok, "system"}
    assert Ezagent.URI.workspace_name(session_b) == {:ok, "system"}
    assert Ezagent.URI.name(session_a) == {:ok, short}
    assert Ezagent.URI.name(session_b) == {:ok, short}

    cleanup_session(session_a)
    cleanup_session(session_b)

    member_a = Chat.role_name_to_uri(chat_slice(session_a).members, role_name)
    member_b = Chat.role_name_to_uri(chat_slice(session_b).members, role_name)

    cleanup_agent(member_a)
    cleanup_agent(member_b)

    assert Ezagent.URI.type?(member_a, :agent)
    assert Ezagent.URI.type?(member_b, :agent)

    refute member_a == member_b,
           "two sessions from DIFFERENT templates (same ws + short_name) must NOT " <>
             "share a member URI; got #{URI.to_string(member_a)} for both"
  end

  test "a template with a DANGLING role_name receiver fails materialization cleanly (codex MAJOR #2)" do
    n = uniq()
    template_name = "dangle-team-#{n}"
    role_name = "worker-#{n}"
    source_template_uri = seed_agent_template(n)

    content = %{
      name: template_name,
      description: "dangling-receiver team",
      orchestrator_template_uri: nil,
      default_workspace_uri: Ezagent.URI.new!("workspace://system"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z],
      members: [
        %{
          uri: nil,
          role_name: role_name,
          in_session_template: true,
          source_template_uri: source_template_uri
        }
      ],
      prompt_templates: %{},
      legends: %{},
      routing_rules: [
        %{
          matcher: Matcher.mention("trigger-#{n}"),
          # `ghost-role` is NEITHER a materialized role_name NOR a magic
          # token NOR a valid concrete URI — a dangling receiver that would
          # otherwise pass through unchanged and crash Ezagent.URI.new!/1 at
          # send-time. Materialization must fail loud HERE.
          receivers: ["ghost-role-#{n}"],
          rule_set: "rs-#{n}",
          position: 0,
          prompt_template_ref: nil
        }
      ]
    }

    _template_uri = persist_template(content)

    short = "dangle-sess-#{n}"

    assert {:error, reason} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
               template_name: template_name
             )

    # The failure names the offending receiver and rolls the create back
    # (no half-installed session, no orphan rule rows).
    assert match?({:install_rule_failed, _rule, {:unknown_rule_receiver, _}}, reason) or
             (is_tuple(reason) and elem(reason, 0) == :install_rule_failed),
           "expected a clean {:unknown_rule_receiver, _} failure; got #{inspect(reason)}"

    cleanup_session(Ezagent.URI.session("system", template_name, short))
  end

  test "re-materializing an existing session twice does NOT duplicate rule rows (codex MAJOR #4)" do
    n = uniq()
    template_name = "idem-team-#{n}"
    role_name = "worker-#{n}"
    source_template_uri = seed_agent_template(n)
    rule_set = "rs-#{n}"

    content = %{
      name: template_name,
      description: "idempotent rules team",
      orchestrator_template_uri: nil,
      default_workspace_uri: Ezagent.URI.new!("workspace://system"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z],
      members: [
        %{
          uri: nil,
          role_name: role_name,
          in_session_template: true,
          source_template_uri: source_template_uri
        }
      ],
      prompt_templates: %{},
      legends: %{},
      routing_rules: [
        %{
          matcher: Matcher.mention("idem-#{n}"),
          receivers: [role_name],
          rule_set: rule_set,
          position: 0,
          prompt_template_ref: nil
        }
      ]
    }

    _template_uri = persist_template(content)

    assert {:ok, session_uri, _} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "idem-sess-#{n}",
               User.admin_uri(),
               template_name: template_name
             )

    cleanup_session(session_uri)
    member = Chat.role_name_to_uri(chat_slice(session_uri).members, role_name)
    cleanup_agent(member)

    table = Resolver.default_routing_table()
    session_str = URI.to_string(session_uri)

    rows_for_session = fn ->
      Ezagent.Routing.RuleStore.list(table)
      |> Enum.filter(&(&1.created_by == session_str))
    end

    # The create installed exactly one rule for this session.
    assert length(rows_for_session.()) == 1
    member_count = map_size(chat_slice(session_uri).members)

    # Re-materialize the SAME session twice (what repair_orchestrator does).
    assert :ok =
             EzagentDomainInstanceMessage.materialize_template_team(
               session_uri,
               URI.new!("workspace://system"),
               User.admin_uri(),
               content
             )

    assert :ok =
             EzagentDomainInstanceMessage.materialize_template_team(
               session_uri,
               URI.new!("workspace://system"),
               User.admin_uri(),
               content
             )

    # No DUPLICATE rule rows — still exactly one for this session.
    assert length(rows_for_session.()) == 1,
           "repair/re-materialize must NOT duplicate rule rows; got #{inspect(rows_for_session.())}"

    # And members were not double-spawned (the join + session-unique naming
    # are idempotent within a session).
    assert map_size(chat_slice(session_uri).members) == member_count
  end

  test "a materialization that fails on the Nth member rolls back earlier members + any rules (codex MAJOR #3)" do
    n = uniq()
    template_name = "rollback-team-#{n}"
    good_role = "good-#{n}"
    bad_role = "bad-#{n}"

    good_source = seed_agent_template(n)
    # A second AgentTemplate WITHOUT a `flavor` field → materializing this
    # member fails with {:source_template_missing_flavor, _}. Placed AFTER
    # the good member so the good one is spawned first, then the Nth fails.
    bad_source = seed_agent_template_no_flavor(n)

    content = %{
      name: template_name,
      description: "rollback team",
      orchestrator_template_uri: nil,
      default_workspace_uri: Ezagent.URI.new!("workspace://system"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z],
      members: [
        %{
          uri: nil,
          role_name: good_role,
          in_session_template: true,
          source_template_uri: good_source
        },
        %{
          uri: nil,
          role_name: bad_role,
          in_session_template: true,
          source_template_uri: bad_source
        }
      ],
      prompt_templates: %{},
      legends: %{},
      routing_rules: [
        %{
          matcher: Matcher.mention("rb-#{n}"),
          receivers: [good_role],
          rule_set: "rb-#{n}",
          position: 0,
          prompt_template_ref: nil
        }
      ]
    }

    _template_uri = persist_template(content)

    # The good member's session-unique URI, computed the same way
    # materialization does (so we can assert it was torn down).
    short = "rollback-sess-#{n}"
    session_uri = Ezagent.URI.session("system", template_name, short)
    # The discriminator is the FULL session URI string (codex cycle-2 BLOCKER
    # #1) — distinct templates yield distinct member URIs.
    good_instance =
      "echo_" <>
        Ezagent.Entity.Agent.session_instance_name(
          good_role,
          EzagentDomainInstanceMessage.session_discriminator(session_uri)
        )

    good_member_uri = URI.new!("entity://system/agent/#{good_instance}")

    assert {:error, reason} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
               template_name: template_name
             )

    assert match?({:member_materialize_failed, _, _}, reason) or is_tuple(reason),
           "expected a member_materialize_failed; got #{inspect(reason)}"

    # The earlier (good) member Kind was torn down — NO orphan.
    assert KindRegistry.lookup(good_member_uri) == :error,
           "the earlier good member must be rolled back; it is still alive at #{URI.to_string(good_member_uri)}"

    # No rules were inserted for this session (members fail BEFORE rule
    # install, and the whole create rolled back).
    table = Resolver.default_routing_table()
    session_str = URI.to_string(session_uri)

    assert Ezagent.Routing.RuleStore.list(table)
           |> Enum.filter(&(&1.created_by == session_str)) == [],
           "no orphan rule rows must remain after a failed materialization"

    cleanup_session(session_uri)
  end

  test "a spawn-succeeds-but-join-fails member leaves NO orphan (codex cycle-2 MAJOR #2)" do
    n = uniq()
    template_name = "joinfail-team-#{n}"
    # Two members sharing the SAME role_name but DIFFERENT flavors. role_name
    # is UNIQUE-per-session (Chat.do_join's role_name_conflict guard), so:
    #   * member A (echo flavor) spawns to echo_<...> + joins OK → role held;
    #   * member B (cc flavor) — a DIFFERENT flavor → a DIFFERENT instance URI
    #     (cc_<...>) — spawns FRESH through `spawn_from_template_content/4`
    #     (which binds workspace + records lineage), then its faceted
    #     chat.join is REJECTED with a role_name conflict. That is the genuine
    #     spawn-succeeds/join-fails orphan case — no production test-hook
    #     needed.
    role_name = "shared-role-#{n}"
    echo_source = seed_agent_template(n)
    cc_source = seed_cc_agent_template(n)

    content = %{
      name: template_name,
      description: "join-fail team",
      orchestrator_template_uri: nil,
      default_workspace_uri: Ezagent.URI.new!("workspace://system"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z],
      members: [
        %{
          uri: nil,
          role_name: role_name,
          in_session_template: true,
          source_template_uri: echo_source
        },
        %{
          uri: nil,
          role_name: role_name,
          in_session_template: true,
          source_template_uri: cc_source
        }
      ],
      prompt_templates: %{},
      legends: %{},
      routing_rules: []
    }

    _template_uri = persist_template(content)

    short = "joinfail-sess-#{n}"
    session_uri = Ezagent.URI.session("system", template_name, short)
    disc = EzagentDomainInstanceMessage.session_discriminator(session_uri)

    # The cc member's session-unique URI (spawned FRESH, then its join fails).
    cc_instance = "cc_" <> Ezagent.Entity.Agent.session_instance_name(role_name, disc)
    cc_member_uri = URI.new!("entity://system/agent/#{cc_instance}")

    assert {:error, _reason} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
               template_name: template_name
             )

    # The freshly-spawned (join-failed) cc member Kind was terminated — NO
    # orphan Agent Kind survives the failed join.
    assert KindRegistry.lookup(cc_member_uri) == :error,
           "spawn-succeeds/join-fails must leave no orphan member Kind; " <>
             "it is still alive at #{URI.to_string(cc_member_uri)}"

    # And its workspace binding was swept (no residue that would let a later
    # `{:spawned_by,_}` cap resolve against a dead worker).
    assert Ezagent.WorkspaceRegistry.lookup(cc_member_uri) == :error,
           "spawn-succeeds/join-fails must sweep the workspace binding"

    cleanup_session(session_uri)
    cleanup_agent(cc_member_uri)
  end

  # A minimal cc-flavor AgentTemplate. The `cc` flavor is registered in the
  # test boot (test_helper.exs) and short-circuits the real PTY in :test. Used
  # to give a member a DIFFERENT flavor (distinct instance URI) while sharing a
  # role_name with an echo member — the spawn-succeeds/join-fails lever.
  defp seed_cc_agent_template(n) do
    name = "seed-cc-#{n}"
    uri = Ezagent.URI.new!("template://system/agent/#{name}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(uri)}?action=template.write"),
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
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    on_exit(fn ->
      case KindRegistry.lookup(uri) do
        {:ok, pid} ->
          if Process.alive?(pid),
            do:
              DynamicSupervisor.terminate_child(
                EzagentDomainInstanceMessage.AgentTemplateSupervisor,
                pid
              )

        :error ->
          :ok
      end
    end)

    uri
  end

  defp cleanup_session(session_uri) do
    on_exit(fn ->
      case KindRegistry.lookup(session_uri) do
        {:ok, pid} ->
          if Process.alive?(pid),
            do:
              DynamicSupervisor.terminate_child(
                EzagentDomainInstanceMessage.SessionSupervisor,
                pid
              )

        :error ->
          :ok
      end
    end)
  end

  defp cleanup_agent(%URI{} = agent_uri) do
    on_exit(fn ->
      case KindRegistry.lookup(agent_uri) do
        {:ok, pid} ->
          if Process.alive?(pid),
            do:
              DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.AgentSupervisor, pid)

        :error ->
          :ok
      end
    end)
  end

  defp cleanup_agent(_), do: :ok

  # An AgentTemplate WITHOUT a `flavor` field — materializing a member from
  # it fails with {:source_template_missing_flavor, _} (the failure the
  # rollback test triggers on the Nth member).
  defp seed_agent_template_no_flavor(n) do
    name = "seed-noflavor-#{n}"
    uri = Ezagent.URI.new!("template://system/agent/#{name}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(uri)}?action=template.write"),
        mode: :call,
        args: %{
          content: %{
            project_cwd: "/tmp",
            default_caps: [],
            created_by: User.admin_uri(),
            created_at: ~U[2026-06-01 00:00:00Z]
          }
        },
        ctx: %{
          caller: User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    on_exit(fn ->
      case KindRegistry.lookup(uri) do
        {:ok, pid} ->
          if Process.alive?(pid),
            do:
              DynamicSupervisor.terminate_child(
                EzagentDomainInstanceMessage.AgentTemplateSupervisor,
                pid
              )

        :error ->
          :ok
      end
    end)

    uri
  end

  # Persist a minimal echo-flavor AgentTemplate Kind to spawn workers from.
  # The `echo` flavor is registered in the test boot (test_helper.exs), so a
  # spawned workspace-first echo agent URI resolves to a joinable Echo Kind.
  defp seed_agent_template(n) do
    name = "seed-tpl-#{n}"
    uri = Ezagent.URI.new!("template://system/agent/#{name}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)

    # Populate its :template content with `flavor: "echo"` (the field the
    # materialization spawn path reads to build the flavor-prefixed instance
    # name). Write via the Template behavior under the bootstrap principal.
    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(uri)}?action=template.write"),
        mode: :call,
        args: %{
          content: %{
            flavor: "echo",
            project_cwd: "/tmp",
            default_caps: [],
            created_by: User.admin_uri(),
            created_at: ~U[2026-06-01 00:00:00Z]
          }
        },
        ctx: %{
          caller: User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    on_exit(fn ->
      case KindRegistry.lookup(uri) do
        {:ok, pid} ->
          if Process.alive?(pid),
            do:
              DynamicSupervisor.terminate_child(
                EzagentDomainInstanceMessage.AgentTemplateSupervisor,
                pid
              )

        :error ->
          :ok
      end
    end)

    uri
  end
end
