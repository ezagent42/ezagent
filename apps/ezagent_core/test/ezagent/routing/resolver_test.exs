defmodule Ezagent.Routing.ResolverTest do
  @moduledoc """
  Phase 3a-step 3: Resolver tests.

  Each test declares its OWN routing table (unique per test, owned by
  the test process) and configures `Ezagent.Routing.Resolver` to query
  that table via `Application.put_env(:ezagent_core, :routing_tables, ...)`.
  This avoids conflict with the live `EzagentDomainInstanceMessage.Application` which
  owns `MentionRouting` and `SessionRouting` for the running app.
  """

  use ExUnit.Case, async: false
  alias Ezagent.{Message, RoutingRegistry}
  alias Ezagent.Routing.{Matcher, Resolver}

  setup do
    test_table = :"resolver_test_#{System.unique_integer([:positive])}"
    :ok = RoutingRegistry.declare_table(test_table, key_uniqueness: :duplicate)

    original = Application.get_env(:ezagent_core, :routing_tables)
    Application.put_env(:ezagent_core, :routing_tables, [test_table])

    on_exit(fn ->
      if original do
        Application.put_env(:ezagent_core, :routing_tables, original)
      else
        Application.delete_env(:ezagent_core, :routing_tables)
      end
    end)

    {:ok, table: test_table}
  end

  defp msg(text \\ "hello", mentions \\ []) do
    Message.new(URI.new!("entity://system/user/admin"), %{text: text, attachments: []},
      mentions: mentions
    )
  end

  describe "resolve/3" do
    test "returns [] when no rule matches → caller falls through to in-session default" do
      assert [] = Resolver.resolve(msg(), URI.new!("session://system/default/main"), [])
    end

    test "F14 (#98): an Always rule does NOT route a message back to its own sender (self-loop protection)",
         %{table: t} do
      echo = URI.new!("entity://system/agent/echo_self-loop")
      session = URI.new!("session://system/default/main")
      # `Always → echo`: matches EVERY message and targets echo.
      :ok = RoutingRegistry.put(t, Matcher.always(), [URI.to_string(echo)])

      # A message SENT BY echo (its own reply) must NOT be routed back to echo —
      # otherwise the Always rule re-fires on echo's reply → self-loop flood.
      echo_reply = Message.new(echo, %{text: "my own reply", attachments: []})
      assert [] = Resolver.resolve(echo_reply, session, [])

      # Control: the SAME Always rule still routes a DIFFERENT sender's message to
      # echo (the rule isn't broken — only the self-route is excluded).
      admin_msg =
        Message.new(URI.new!("entity://system/user/admin"), %{text: "hi", attachments: []})

      assert [echo] == Resolver.resolve(admin_msg, session, [])
    end

    test "mention(X) rule fires when message mentions X — returns receivers", %{table: t} do
      target = URI.new!("entity://team-alpha/agent/test_cc-builder")

      :ok =
        RoutingRegistry.put(t, Matcher.mention(target), ["session://team-alpha/default/oncall"])

      result =
        Resolver.resolve(msg("hi", [target]), URI.new!("session://system/default/main"), [])

      assert result == [URI.new!("session://team-alpha/default/oncall")]
    end

    test "additive: multiple rules matching → union receivers, deduplicated", %{table: t} do
      target = URI.new!("entity://team-alpha/agent/test_X")

      :ok =
        RoutingRegistry.put(t, Matcher.mention(target), [
          "session://team-alpha/default/A",
          "session://team-alpha/default/B"
        ])

      :ok =
        RoutingRegistry.put(t, Matcher.always(), [
          "session://team-alpha/default/B",
          "session://team-alpha/default/C"
        ])

      result =
        Resolver.resolve(msg("hi", [target]), URI.new!("session://system/default/main"), [])

      uris = result |> Enum.map(&URI.to_string/1) |> Enum.sort()

      assert uris == [
               "session://team-alpha/default/A",
               "session://team-alpha/default/B",
               "session://team-alpha/default/C"
             ]
    end

    test "text_contains rule matches body", %{table: t} do
      :ok =
        RoutingRegistry.put(t, Matcher.text_contains("urgent"), [
          "session://team-alpha/default/oncall"
        ])

      assert Resolver.resolve(
               msg("server urgent down"),
               URI.new!("session://system/default/main"),
               []
             ) ==
               [URI.new!("session://team-alpha/default/oncall")]

      # No match if word absent
      assert Resolver.resolve(msg("all green"), URI.new!("session://system/default/main"), []) ==
               []
    end

    test "table not declared in app env → silently skip (returns [])" do
      Application.put_env(:ezagent_core, :routing_tables, [:nonexistent_table])
      assert [] = Resolver.resolve(msg(), URI.new!("session://system/default/main"), [])
    end
  end

  describe "resolve_with_ctx/4 (matched-rule context, §3.5)" do
    test "returns ctx with the matched rule's prompt_template_ref + rule_id", %{table: t} do
      :ok =
        RoutingRegistry.put(t, Matcher.always(), %{
          receivers: ["session://team-alpha/default/oncall"],
          applies_to_users: [],
          workspace_uri: nil,
          rule_id: 42,
          rule_set: "telephone",
          prompt_template_ref: "telephone_hop"
        })

      assert [{uri, ctx}] =
               Resolver.resolve_with_ctx(msg(), URI.new!("session://system/default/main"), [], [])

      assert URI.to_string(uri) == "session://team-alpha/default/oncall"
      assert ctx.prompt_template_ref == "telephone_hop"
      assert ctx.rule_id == 42
      assert ctx.rule_set == "telephone"
    end

    test "ctx is nil for a legacy plain-list rule", %{table: t} do
      :ok = RoutingRegistry.put(t, Matcher.always(), ["session://team-alpha/default/oncall"])

      assert [{_uri, nil}] =
               Resolver.resolve_with_ctx(msg(), URI.new!("session://system/default/main"), [], [])
    end

    test "resolve/4 still returns bare [URI] (back-compat — delegates to resolve_with_ctx)",
         %{table: t} do
      :ok = RoutingRegistry.put(t, Matcher.always(), ["session://team-alpha/default/oncall"])

      assert Resolver.resolve(msg(), URI.new!("session://system/default/main"), [], []) ==
               [URI.new!("session://team-alpha/default/oncall")]
    end

    test "duplicate recipient from two rules → lower rule_id ctx wins (deterministic)",
         %{table: t} do
      recv = "session://team-alpha/default/oncall"
      base = %{receivers: [recv], applies_to_users: [], workspace_uri: nil}

      # Two rules both match "hello" + route to the SAME recipient with
      # different prompt_template_refs. Insert the HIGHER rule_id first so a
      # naive ETS-order first-wins would pick rule 2 — the deterministic
      # tie-break must pick the lower rule_id (1) regardless of insert order.
      :ok =
        RoutingRegistry.put(
          t,
          Matcher.text_contains("hello"),
          Map.merge(base, %{rule_id: 2, prompt_template_ref: "from_rule_2"})
        )

      :ok =
        RoutingRegistry.put(
          t,
          Matcher.always(),
          Map.merge(base, %{rule_id: 1, prompt_template_ref: "from_rule_1"})
        )

      assert [{uri, ctx}] =
               Resolver.resolve_with_ctx(
                 msg("hello"),
                 URI.new!("session://system/default/main"),
                 [],
                 []
               )

      assert URI.to_string(uri) == recv
      assert ctx.rule_id == 1
      assert ctx.prompt_template_ref == "from_rule_1"
    end
  end

  describe "tagged receivers" do
    test "from_role matcher evaluates against the current session member snapshot", %{table: t} do
      responser = URI.new!("entity://system/agent/hello_responser")
      builder = URI.new!("entity://system/agent/hello_builder")
      session_uri = Ezagent.URI.session(:system, :default, "hello")

      :ok =
        RoutingRegistry.put(t, Matcher.from_role("responser"), %{
          receivers: [Ezagent.Routing.Receiver.role("builder")],
          applies_to_users: [],
          rule_id: 12
        })

      message = Message.new(responser, %{text: "[need-build] hi", attachments: []})
      members = %{responser => %{role_name: "responser"}, builder => %{role_name: "builder"}}

      assert [{^builder, %{rule_id: 12}}] =
               Resolver.resolve_with_ctx(message, session_uri, Map.keys(members),
                 members_snapshot: members,
                 role_resolver: fn
                   "builder", _ctx -> builder
                 end
               )

      reassigned = %{responser => %{role_name: "observer"}, builder => %{role_name: "builder"}}

      assert [] =
               Resolver.resolve_with_ctx(message, session_uri, Map.keys(reassigned),
                 members_snapshot: reassigned,
                 role_resolver: fn "builder", _ctx -> builder end
               )
    end

    test "tagged role receivers resolve through the route-time role resolver", %{table: t} do
      role_target = Ezagent.URI.agent(:team_alpha, "cc_orchestrator")
      session_uri = Ezagent.URI.session(:team_alpha, :default, "main")

      :ok =
        RoutingRegistry.put(t, Matcher.always(), %{
          receivers: [Ezagent.Routing.Receiver.role("orchestrator")],
          applies_to_users: []
        })

      assert [{^role_target, _ctx}] =
               Resolver.resolve_with_ctx(msg(), session_uri, [],
                 role_resolver: fn
                   "orchestrator", _ctx -> role_target
                 end
               )
    end

    test "tagged role receivers can fan out through an injected multi-holder resolver", %{
      table: t
    } do
      holder_a = Ezagent.URI.user(:team_alpha, "supervisor-a")
      holder_b = Ezagent.URI.user(:team_alpha, "supervisor-b")
      session_uri = Ezagent.URI.session(:team_alpha, :default, "main")

      :ok =
        RoutingRegistry.put(t, Matcher.always(), %{
          receivers: [Ezagent.Routing.Receiver.role("supervisor")],
          applies_to_users: []
        })

      assert [{^holder_a, _ctx}, {^holder_b, _ctx2}] =
               Resolver.resolve_with_ctx(msg(), session_uri, [],
                 role_resolver: fn
                   "supervisor", _ctx -> [holder_a, holder_b]
                 end
               )
    end

    test "legacy bare role-looking strings are not role receivers", %{table: t} do
      :ok =
        RoutingRegistry.put(t, Matcher.always(), %{
          receivers: ["orchestrator"],
          applies_to_users: []
        })

      assert_raise ArgumentError, fn ->
        Resolver.resolve_with_ctx(
          msg(),
          Ezagent.URI.session(:team_alpha, :default, "main"),
          [],
          role_resolver: fn "orchestrator", _ctx ->
            flunk("legacy string reached role resolver")
          end
        )
      end
    end
  end

  # RF-6 — passive-actor (non-principal data-actor) isolation. The `passive?`
  # predicate is injected via opts (parallel to `role_resolver`); the domain call
  # site sources it from the stored agent attribute. Here it is injected directly
  # so the gates are tested as pure functions. A passive actor must NOT receive
  # chat via ANY rule type, and must NOT be a valid @-mention target; a NORMAL
  # agent (no opt, or `passive? -> false`) is unaffected.
  describe "RF-6 passive-actor isolation" do
    setup do
      # SAME workspace (`system`) as the session, so `valid_member?` PASSES for
      # the passive URI in the `$mentions` test — the exclusion is then
      # attributable to the passive gate, not a cross-workspace drop (otherwise
      # the mention-gate test would be a false positive that passes even if the
      # gate-3 reject is deleted).
      passive = URI.new!("entity://system/agent/kanban_board")
      normal = URI.new!("entity://system/agent/cc_worker")
      session = URI.new!("session://system/default/main")

      # Predicate marking ONLY `passive` as a passive actor.
      passive? = fn uri -> URI.to_string(uri) == URI.to_string(passive) end

      {:ok, passive: passive, normal: normal, session: session, passive?: passive?}
    end

    test "passive actor does NOT receive via an Always→X rule (concrete URI / Always)",
         %{table: t, passive: passive, session: session, passive?: passive?} do
      :ok = RoutingRegistry.put(t, Matcher.always(), [URI.to_string(passive)])

      assert [] =
               Resolver.resolve(msg(), session, [], passive?: passive?)

      # Control: without the gate the SAME rule routes to the passive URI.
      assert [^passive] = Resolver.resolve(msg(), session, [])
    end

    test "passive actor does NOT receive via a {:from, sender}→X rule (from-matcher)",
         %{table: t, passive: passive, session: session, passive?: passive?} do
      sender = URI.new!("entity://system/user/admin")
      # msg/2's sender is entity://system/user/admin — a `from(sender)` rule fires.
      :ok = RoutingRegistry.put(t, Matcher.from(sender), [URI.to_string(passive)])

      assert [] = Resolver.resolve(msg(), session, [], passive?: passive?)
      assert [^passive] = Resolver.resolve(msg(), session, [])
    end

    test "passive actor does NOT receive via a concrete-URI receiver on a mention rule",
         %{table: t, passive: passive, session: session, passive?: passive?} do
      trigger = URI.new!("entity://team-alpha/agent/trigger")
      :ok = RoutingRegistry.put(t, Matcher.mention(trigger), [URI.to_string(passive)])

      assert [] =
               Resolver.resolve(msg("hi", [trigger]), session, [], passive?: passive?)

      assert [^passive] = Resolver.resolve(msg("hi", [trigger]), session, [])
    end

    test "passive actor is NOT a valid @-mention target ($mentions gate)",
         %{table: t, passive: passive, session: session, passive?: passive?} do
      # The mention-gated default: `$mentions` resolves to mentioned members.
      :ok =
        RoutingRegistry.put(t, Matcher.always(), [Resolver.mentions_token()])

      # passive is BOTH mentioned AND a same-workspace session member, so it
      # PASSES `valid_member?` — only the passive gate (gate 3) can keep it out.
      members = [passive]

      # Control (attribution): WITHOUT the passive predicate the SAME mention of
      # the SAME member IS delivered — proving `valid_member?` admits it and the
      # exclusion below is the passive gate, not the membership filter.
      assert [^passive] = Resolver.resolve(msg("hi", [passive]), session, members)

      # With the passive gate, the mentioned passive member is dropped.
      assert [] =
               Resolver.resolve(msg("hi", [passive]), session, members, passive?: passive?)

      # Control: a NORMAL agent member, mentioned, IS delivered to even with the
      # predicate present (regression — only the passive URI is excluded).
      normal = URI.new!("entity://system/agent/cc_normal")

      assert [^normal] =
               Resolver.resolve(msg("hi", [normal]), session, [normal], passive?: passive?)
    end

    test "a NORMAL agent is unaffected — receives via every rule type (regression)",
         %{table: t, normal: normal, session: session, passive?: passive?} do
      :ok = RoutingRegistry.put(t, Matcher.always(), [URI.to_string(normal)])

      # With the passive? predicate present, a NON-passive agent still delivers.
      assert [^normal] = Resolver.resolve(msg(), session, [], passive?: passive?)
    end

    test "no passive? opt → default never-passive predicate → byte-identical (regression)",
         %{table: t, passive: passive, session: session} do
      # The STRUCTURAL regression guarantee: an existing caller passing no opt
      # treats nothing as passive, so the passive URI is delivered to exactly as
      # before RF-6.
      :ok = RoutingRegistry.put(t, Matcher.always(), [URI.to_string(passive)])

      assert [^passive] = Resolver.resolve(msg(), session, [])
      assert [^passive] = Resolver.resolve(msg(), session, [], [])
    end
  end
end
