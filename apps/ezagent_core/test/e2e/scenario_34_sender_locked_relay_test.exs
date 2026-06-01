defmodule Ezagent.E2E.Scenario34_SenderLockedRelayTest do
  @moduledoc """
  E2E Scenario 34 — sender-locked relay (传话游戏) — DETERMINISTIC TIER.

  This is the **headline deterministic invariant gate** for the
  team-routing-unification cutover (spec §9 "Scenario 34", plan PR-9). It
  proves, at the ROUTING LAYER (`Ezagent.Routing.Resolver.resolve_with_ctx/4`
  + the `Ezagent.Routing.Matcher` chain, with NO live agents and NO model in
  the loop), that the FULL relay/star-cycle topology resolves end-to-end —

      @传话游戏 ─(legend entry: mention(传话游戏))→ relay-cc
      relay-cc ─(from(relay-cc))→ relay-codex
      relay-codex ─(from(relay-codex))→ relay-curl   (terminal — spec §4)

  expressed PURELY via legend + rule-set + prompt-template (spec §4 worked
  example), with **NO baton token, NO `next_hop`, NO model-computed routing**:
  the routing table IS the chain. Each hop carries the correct
  `prompt_template_ref` ctx (so PR-4's `render_for_delivery/4` injects
  `telephone_hop` at every hop), and the entry fires through the SYMBOLIC
  legend-trigger path (NOT the URI-mention path — a CJK legend name can't be
  cast to a URI).

  ## Why a deterministic resolver-level test is the automatable core

  The LIVE tier (real cc/codex/curl PTYs replying through the bound Feishu
  group, agent-browser screenshot per `feedback_esr_e2e_standards`) needs
  Allen's environment (running agent services + the real Feishu group +
  provider creds). That tier is `@tag :live` (excluded by default) +
  documented in `docs/scenarios/34-sender-locked-relay/scenario.md`. What is
  fully automatable in CI — and what catches a routing regression in the
  cutover — is the resolver-level topology assertion below. The agents'
  ACTUAL reply text is irrelevant to routing: the ONLY thing that advances
  the chain is `{:from, X}` matching the sender of whatever the agent emits.
  That is the "no model-computed routing" property this test pins.

  ## The no-baton structural gate (the §9 invariant test)

  `feedback_completion_requires_invariant_test`: this file fails if the chain
  ever requires a model to compute the next hop. The gate is structural —
  every hop matcher is `{:from, <previous-member-uri>}` (or `{:mention, …}`
  for the entry), and every receiver is a CONCRETE member URI. No matcher
  reads a baton/next_hop/token field of the message body, and no receiver is
  derived from message content. We assert that property directly over the
  installed rule-set (see "the routing table IS the chain — no baton" test).
  """
  use ExUnit.Case, async: false

  alias Ezagent.Message
  alias Ezagent.Routing.{Legend, Matcher, Resolver}

  # The relay team (spec §4). role_name → URI; the rule-set keys on the URIs
  # (the resolved members), the legend's member_set keys on role_names.
  @session URI.new!("session://generic/team-alpha/relay-1")
  @operator URI.new!("entity://user/team-alpha/operator")
  @relay_cc URI.new!("entity://agent/team-alpha/cc_relay")
  @relay_codex URI.new!("entity://agent/team-alpha/codex_relay")
  @relay_curl URI.new!("entity://agent/team-alpha/curl_relay")

  @legend_name "传话游戏"
  @rule_set "telephone"
  @hop_template "telephone_hop"

  # The session members — all three relay agents + the operator. The Resolver
  # only routes to URIs it can expand (concrete receivers pass through); the
  # members list matters for the magic-token / valid_member? paths (unused by
  # the concrete sender-locked hops, exercised by the broadcast variant test).
  @members [@operator, @relay_cc, @relay_codex, @relay_curl]

  setup do
    original = Application.get_env(:ezagent_core, :routing_tables)

    on_exit(fn ->
      if original do
        Application.put_env(:ezagent_core, :routing_tables, original)
      else
        Application.delete_env(:ezagent_core, :routing_tables)
      end
    end)

    table = install_telephone_rule_set()
    %{table: table}
  end

  # Install the `telephone` rule-set into an ISOLATED RoutingRegistry ETS
  # table (mirrors `legend_test.exs`' `install_table/1`). The value maps mirror
  # `RuleStore.load_into_registry/1`'s shape so the Resolver's ctx threading +
  # magic expansion run EXACTLY as in production (no DB needed — this is the
  # pure routing-layer tier).
  #
  # This is the SoT of the chain — the literal expression of spec §4:
  #   pos 0  mention(传话游戏)      → relay-cc     [ENTRY]
  #   pos 1  from(relay-cc)         → relay-codex
  #   pos 2  from(relay-codex)      → relay-curl   [TERMINAL]
  defp install_telephone_rule_set do
    table = String.to_atom("scenario34_relay_#{System.unique_integer([:positive])}")
    :ok = Ezagent.RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

    rules = [
      {Matcher.mention(@legend_name), @relay_cc, 0},
      {Matcher.from(@relay_cc), @relay_codex, 1},
      {Matcher.from(@relay_codex), @relay_curl, 2}
    ]

    Enum.each(rules, fn {matcher, receiver, position} ->
      :ok =
        Ezagent.RoutingRegistry.put(
          table,
          matcher,
          rule_value(URI.to_string(receiver), position)
        )
    end)

    Application.put_env(:ezagent_core, :routing_tables, [table])
    table
  end

  # The loaded-rule value shape (RuleStore.load_into_registry/1): single
  # receiver + rule identity + the shared prompt template ref. position doubles
  # as the deterministic rule_id (stable tie-break + ascending hop order).
  defp rule_value(receiver_str, position) do
    %{
      receivers: [receiver_str],
      applies_to_users: [],
      workspace_uri: nil,
      rule_id: position,
      rule_set: @rule_set,
      prompt_template_ref: @hop_template
    }
  end

  defp msg(sender, text, opts \\ []) do
    Message.new(sender, %{text: text}, opts)
  end

  # Resolve and return the single {recipient_uri_string, ctx} for a message
  # (the rule-set is single-receiver per hop, so exactly one or zero results).
  defp resolve_one(message) do
    case Resolver.resolve_with_ctx(message, @session, @members, []) do
      [{uri, ctx}] -> {URI.to_string(uri), ctx}
      [] -> :none
      other -> {:multiple, other}
    end
  end

  describe "GATE (a) — the legend entry fires → first hop" do
    test "@传话游戏 (via legend_triggers, NOT mentions) resolves to relay-cc" do
      # The legend NAME rides the VIRTUAL legend_triggers field — a parser
      # (LiveView / Feishu) classifies it via Legend.mention_token/2 and emits
      # the symbolic name here instead of :mentions (a CJK name can't be cast
      # to a URI). The entry rule's `mention(传话游戏)` matches against it.
      message = msg(@operator, "@#{@legend_name} 开始", legend_triggers: [@legend_name])

      # The symbolic legend name never pollutes :mentions.
      assert message.mentions == []

      assert {recipient, ctx} = resolve_one(message)
      assert recipient == URI.to_string(@relay_cc)
      assert ctx.prompt_template_ref == @hop_template
      assert ctx.rule_set == @rule_set
    end

    test "the legend resolves through the registry to its bound rule-set (not a URI mention)" do
      legends =
        Legend.put(%{}, @legend_name,
          member_set: ["relay-cc", "relay-codex", "relay-curl"],
          bound_rule_set: @rule_set,
          fold: true
        )

      # GATE b for legends: a @legend classifies as a legend token, intercepted
      # BEFORE the URI-mention path — it never reaches the concrete-URI matcher.
      assert {:legend, @legend_name} = Legend.mention_token(legends, @legend_name)
      assert {:ok, entry} = Legend.resolve(legends, @legend_name)
      assert entry.bound_rule_set == @rule_set
    end
  end

  describe "GATE (b) — each {:from, X} hop routes to the next, carrying ctx" do
    test "from(relay-cc) → relay-codex with telephone_hop ctx" do
      # relay-cc replies ANYTHING — the body is irrelevant to routing. The ONLY
      # thing that advances the chain is the SENDER (relay-cc), matched by the
      # next rule's {:from, relay-cc}. No baton in the body.
      message = msg(@relay_cc, "苹果。香蕉。")
      assert {recipient, ctx} = resolve_one(message)
      assert recipient == URI.to_string(@relay_codex)
      assert ctx.prompt_template_ref == @hop_template
    end

    test "from(relay-codex) → relay-curl with telephone_hop ctx" do
      message = msg(@relay_codex, "完全不同的内容，路由不看正文。")
      assert {recipient, ctx} = resolve_one(message)
      assert recipient == URI.to_string(@relay_curl)
      assert ctx.prompt_template_ref == @hop_template
    end

    test "relay-curl is TERMINAL — its reply matches no hop (spec §4 linear chain)" do
      # The spec §4 worked example is a LINEAR relay terminating at curl (no
      # rule keys on from(relay-curl)). The chain ends; the curl reply mirrors
      # OUT (to humans / Feishu) but does not loop back.
      message = msg(@relay_curl, "菠萝。结束。")
      assert resolve_one(message) == :none
    end
  end

  describe "GATE (c) — the FULL chain resolves end-to-end with NO model-computed routing" do
    test "drive the whole relay hop-by-hop purely from sender identity" do
      # Simulate the round-trip the way production runs it: each hop's recipient
      # becomes the next message's SENDER (the agent that replied). At NO point
      # does any model emit a next-hop token — the test advances the chain ONLY
      # by feeding the previous recipient as the next sender. If the routing
      # table did not encode the chain, this loop would not terminate at curl.
      entry = msg(@operator, "@#{@legend_name} start", legend_triggers: [@legend_name])

      chain = drive_chain(entry, [])

      # The full ordered topology: operator entry → cc → codex → curl → end.
      assert chain == [
               URI.to_string(@relay_cc),
               URI.to_string(@relay_codex),
               URI.to_string(@relay_curl)
             ]
    end

    test "the routing table IS the chain — NO baton / next_hop / model-computed receiver" do
      # The structural invariant gate (feedback_completion_requires_invariant_test):
      # FAIL if a slot-style or model-computed-routing mechanism reappears.
      #
      # Property 1: every hop matcher reads ONLY sender identity (`from`) or the
      # symbolic legend trigger (`mention`) — NEVER a body/content field. A
      # baton/next_hop scheme would necessarily key on message CONTENT
      # (text_contains/text_matches on a token), so the absence of any
      # content-reading matcher in the relay set is the structural proof.
      table = Application.get_env(:ezagent_core, :routing_tables) |> hd()
      rows = Ezagent.RoutingRegistry.list_all(table)

      matchers = Enum.map(rows, fn {matcher, _value} -> matcher end)

      assert Enum.all?(matchers, fn
               {:from, _uri} -> true
               {:mention, _name} -> true
               _ -> false
             end),
             "relay hops must key on sender (`from`) / legend (`mention`) ONLY — " <>
               "a content-reading matcher (text_contains/text_matches) would mean " <>
               "the model emits a baton the router reads. Got: #{inspect(matchers)}"

      # Property 2: every receiver is a CONCRETE member URI literal — never a
      # value derived from message content at resolve time. (Magic tokens like
      # `$session_members` ARE allowed in general, but the sender-locked relay
      # uses concrete single receivers; either way the receiver is STATIC in
      # the rule, never computed from the body.)
      receivers =
        rows
        |> Enum.flat_map(fn {_matcher, value} -> value.receivers end)

      assert Enum.sort(receivers) ==
               Enum.sort([
                 URI.to_string(@relay_cc),
                 URI.to_string(@relay_codex),
                 URI.to_string(@relay_curl)
               ]),
             "receivers must be the static relay member URIs, not body-derived: " <>
               "#{inspect(receivers)}"

      # Property 3: the chain is single-receiver per hop (spec §3.3 rule-set
      # invariant) — a fan-out / model-pick mechanism would route to >1.
      assert Enum.all?(rows, fn {_m, value} -> length(value.receivers) == 1 end),
             "each relay hop must be single-receiver (rule-set invariant §3.3)"
    end
  end

  describe "GATE (b-variant) — @legend can also broadcast (semantics B, spec §5)" do
    test "a legend entry with $session_members fans out to all members (sender excluded)" do
      # Spec §5 decision A/B: @legend default is 'trigger rule-set' (the relay
      # above); a broadcast variant uses a `$session_members` receiver. Pin that
      # the magic-token expansion still works under the legend-trigger path —
      # proving the same machinery covers both semantics with no new primitive.
      bcast_table = String.to_atom("scenario34_bcast_#{System.unique_integer([:positive])}")
      :ok = Ezagent.RoutingRegistry.declare_table(bcast_table, key_uniqueness: :duplicate)

      :ok =
        Ezagent.RoutingRegistry.put(
          bcast_table,
          Matcher.mention("全员"),
          %{
            receivers: [Resolver.session_members_token()],
            applies_to_users: [],
            workspace_uri: nil,
            rule_id: 0,
            rule_set: "broadcast",
            prompt_template_ref: nil
          }
        )

      Application.put_env(:ezagent_core, :routing_tables, [bcast_table])

      message = msg(@operator, "@全员 hi", legend_triggers: ["全员"])

      recipients =
        Resolver.resolve(message, @session, @members, [])
        |> Enum.map(&URI.to_string/1)
        |> Enum.sort()

      assert recipients ==
               Enum.sort([
                 URI.to_string(@relay_cc),
                 URI.to_string(@relay_codex),
                 URI.to_string(@relay_curl)
               ])
    end
  end

  # Drive the relay: resolve a message, append the recipient, then make that
  # recipient the next SENDER (simulating its reply). Terminates when a hop
  # resolves to no recipient (curl, the terminal). No model in the loop — the
  # next sender is purely the prior recipient. Guards against an accidental
  # infinite loop (a cyclic rule-set would not terminate).
  defp drive_chain(_message, acc) when length(acc) > 10 do
    flunk("relay did not terminate within 10 hops — a routing cycle? acc=#{inspect(acc)}")
  end

  defp drive_chain(message, acc) do
    case resolve_one(message) do
      :none ->
        Enum.reverse(acc)

      {recipient_str, _ctx} ->
        next_sender = URI.new!(recipient_str)
        # The agent at `next_sender` "replies" — body is arbitrary; routing only
        # reads the sender. This is the no-baton property in action.
        next_message = msg(next_sender, "<#{recipient_str} appends a line>")
        drive_chain(next_message, [recipient_str | acc])
    end
  end
end
