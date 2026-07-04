defmodule Ezagent.Orchestrator.SlotRetirementTest do
  @moduledoc """
  team-routing-unification §3.8 (PR-8) — GATE (b), the INVARIANT gate
  (`feedback_completion_requires_invariant_test`): a test that FAILS if a
  slot-style mechanism reappears OR if a rule-set flow requires
  model-computed routing.

  Two halves:

    1. **No slot mechanism** — the retired slot tools
       (`add_agent_slot` / `remove_agent_slot` / `update_agent_template` /
       `write_matcher`) are GONE from the orchestrator surface (Tools +
       McpServer), and `agent_slots` / `receiver_slot_names` no longer
       appear in the live Chat working-copy default nor any tool's JSON
       schema. (Grep-style structural assertions over the SOURCE so the
       guard fails the instant a slot concept is re-added.)

    2. **No model-computed routing** — the relay must be expressible as
       `{:from, role→uri}` rules + a legend trigger, with NO baton token
       emitted by the model. We assert the new tool surface offers a
       sender-routing primitive (`{:from, _}` matchers route via
       `define_rule_set_rule`) and that NO tool name / schema mentions a
       baton / hop-token concept the model would have to populate.
  """

  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Orchestrator.{McpServer, Tools}

  @retired_slot_tools [:add_agent_slot, :remove_agent_slot, :update_agent_template, :write_matcher]

  # PR-8 (transport #53): `tools.ex` relocated to the session domain
  # (operations); `mcp_server.ex` stays in cc (transport). The slot-absence
  # grep guards each in its new home.
  @tools_source File.read!(
                  Path.join(
                    __DIR__,
                    "../../../../ezagent_domain_session/lib/ezagent/orchestrator/tools.ex"
                  )
                )
  @mcp_source File.read!(
                Path.join(__DIR__, "../../../lib/ezagent/orchestrator/mcp_server.ex")
              )

  describe "(b.1) no slot-style mechanism reappears" do
    test "the retired slot tools are GONE from Tools.tool_names/0" do
      names = Tools.tool_names()

      for retired <- @retired_slot_tools do
        refute retired in names,
               "Slot tool #{inspect(retired)} reappeared in Tools.tool_names/0. §3.8 is a " <>
                 "CLEAN CUTOVER — slots are retired; the orchestrator builds teams via " <>
                 "members + rule-sets (add_managed_member / define_rule_set_rule / " <>
                 "define_legend). Adding a slot tool back is the regression this gate blocks."

        refute Tools.tool?(retired),
               "Tools.tool?(#{inspect(retired)}) is true — the slot tool is callable again."
      end
    end

    test "the retired slot tools are GONE from the MCP tool surface" do
      names = McpServer.tool_names()

      for retired <- @retired_slot_tools do
        refute Atom.to_string(retired) in names,
               "Slot tool #{retired} reappeared in McpServer.tool_names/0 (the JSON " <>
                 "surface the LLM sees). §3.8 retires it."
      end
    end

    test "no slot tool has an implementation function on Tools" do
      for retired <- @retired_slot_tools do
        refute Enum.any?([0, 1, 2, 3, 4], fn arity ->
                 function_exported?(Tools, retired, arity)
               end),
               "Tools.#{retired}/n still exists — the slot tool's body was not deleted. " <>
                 "§3.8 requires the dead slot code REMOVED (no shim)."
      end
    end

    test "the live Chat working-copy default carries NO agent_slots key" do
      wc = SessionBehavior.default_template_working_copy()

      refute Map.has_key?(wc, :agent_slots),
             "default_template_working_copy still has :agent_slots — §3.8 drops the residual " <>
               "slot tuple from the live working copy. Got keys: #{inspect(Map.keys(wc))}"
    end

    test "the orchestrator SOURCE has no slot-mechanism identifiers" do
      # Grep-style structural guard: the slot vocabulary must not reappear
      # as a tool name, schema key, dispatch branch, or working-copy field.
      # We match CODE-TOKEN forms (atom literals / `def` heads / JSON-key
      # strings) — NOT bare words — so the moduledoc may still NARRATE the
      # retirement ("the retired `add_agent_slot`") without tripping the
      # gate, while any re-introduced slot CODE fails it instantly.
      forbidden = [
        ":add_agent_slot",
        ":remove_agent_slot",
        ":update_agent_template",
        ":write_matcher",
        "def add_agent_slot",
        "def remove_agent_slot",
        ~s("agent_slots"),
        ":agent_slots",
        ~s("receiver_slot_names"),
        ~s("slot_name"),
        ":slot_name"
      ]

      for needle <- forbidden do
        refute String.contains?(@tools_source, needle),
               "tools.ex contains slot identifier #{inspect(needle)} — §3.8 clean cutover " <>
                 "requires the slot mechanism removed from the orchestrator surface."

        refute String.contains?(@mcp_source, needle),
               "mcp_server.ex contains slot identifier #{inspect(needle)} — §3.8 clean cutover " <>
                 "requires the slot mechanism removed from the orchestrator surface."
      end
    end
  end

  describe "(b.2) no rule-set flow requires model-computed routing" do
    test "the new surface offers MEMBER + RULE-SET tools (not slots)" do
      names = Tools.tool_names()

      for required <- [:add_managed_member, :define_rule_set_rule, :define_legend] do
        assert required in names,
               "The member/rule-set tool #{inspect(required)} is missing — the orchestrator " <>
                 "MUST be able to build a team via members + rule-sets so the relay is a " <>
                 "set of routing rules, NOT model-emitted baton tokens."
      end
    end

    test "define_rule_set_rule routes by MATCHER (incl. {:from, _}), not a model token" do
      # The relay chain is `{:from, cc} → codex`, `{:from, codex} → curl`.
      # The receiver is chosen by the matcher firing on the SENDER — the
      # table IS the baton. The tool takes a matcher_ast + a receiver_role
      # — there is NO arg by which the model passes a next-hop token.
      schema =
        McpServer.tool_schemas()
        |> Enum.find(&(&1["name"] == "define_rule_set_rule"))

      assert schema, "define_rule_set_rule must be in the MCP schema surface"

      props = schema["inputSchema"]["properties"]
      assert Map.has_key?(props, "matcher_ast"), "rule routing is matcher-driven"
      assert Map.has_key?(props, "receiver_role_name"), "the receiver is a static member role"

      # NO schema property is a baton / hop / next-hop token the model must
      # compute — routing is fully expressed by the matcher + receiver.
      all_prop_keys = Map.keys(props) |> Enum.join(" ") |> String.downcase()

      for forbidden <- ["baton", "next_hop", "nexthop", "hop_token", "token"] do
        refute String.contains?(all_prop_keys, forbidden),
               "define_rule_set_rule exposes a #{inspect(forbidden)} arg — that would make the " <>
                 "model compute routing. The relay must be static {:from, X}→Y rules."
      end
    end

    test "a {:from, _} matcher round-trips through normalize (sender-routing primitive exists)" do
      # Proves the {:from, sender} matcher — the relay hop primitive — is a
      # real, parseable matcher the rule-set tool accepts. (No model token
      # needed: a hop fires on the previous agent being the SENDER.)
      from_json = Ezagent.Routing.Matcher.to_json({:from, "entity://system/agent/relay-cc"})
      assert {:ok, {:from, _}} = Ezagent.Routing.Matcher.from_json(from_json)
    end
  end
end
