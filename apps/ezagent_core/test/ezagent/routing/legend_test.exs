defmodule Ezagent.Routing.LegendTest do
  @moduledoc """
  team-routing-unification §3.6 (PR-6) — the Legend registry + resolution layer.

  A Legend is a session-scoped SYMBOLIC handle `%{member_set, bound_rule_set,
  fold}`. It is NOT a member/agent URI, so it must NOT ride
  `Matcher.mention/1` (concrete-URI matching). The registry + `resolve/2`
  provide the dedicated resolution layer the parsers (LiveView + Feishu) consult
  BEFORE the URI-mention path, so a legend name fires its bound rule-set's entry
  rule instead of silent-dropping / mis-routing through the URI matcher.
  """
  use EzagentCore.DataCase, async: false
  alias Ezagent.Routing.{Legend, Matcher, Resolver, RuleStore}
  # `Repo` is aliased by `use EzagentCore.DataCase`; no explicit alias needed (#92).

  setup do
    # Sandbox provided by EzagentCore.DataCase (#92).
    original = Application.get_env(:ezagent_core, :routing_tables)

    on_exit(fn ->
      if original do
        Application.put_env(:ezagent_core, :routing_tables, original)
      else
        Application.delete_env(:ezagent_core, :routing_tables)
      end
    end)

    :ok
  end

  defp uri(s), do: URI.new!(s)

  # A role_name → URI resolver closure over a members map, matching the
  # contract of `Ezagent.ActionSet.Session.role_name_to_uri/2` (domain) WITHOUT
  # taking a core→domain dep — `fold_members/3` accepts any such closure, so
  # core stays pure. The real domain wiring uses Chat.role_name_to_uri/2.
  defp role_resolver(members) do
    fn role ->
      Enum.find_value(members, fn
        {%URI{} = u, %{role_name: ^role}} -> u
        _ -> nil
      end)
    end
  end

  describe "registry — put / get / legend? / names" do
    test "put then get round-trips the entry (member_set / bound_rule_set / fold)" do
      legends =
        Legend.put(%{}, "传话游戏",
          member_set: ["relay-cc", "relay-codex", "relay-curl"],
          bound_rule_set: "telephone",
          fold: true
        )

      assert {:ok, entry} = Legend.get(legends, "传话游戏")
      assert entry.member_set == ["relay-cc", "relay-codex", "relay-curl"]
      assert entry.bound_rule_set == "telephone"
      assert entry.fold == true
      assert entry.name == "传话游戏"
    end

    test "fold defaults to false when not given" do
      legends = Legend.put(%{}, "team", member_set: ["a"], bound_rule_set: "rs")
      assert {:ok, %{fold: false}} = Legend.get(legends, "team")
    end

    test "legend?/2 is true for a registered name, false otherwise" do
      legends = Legend.put(%{}, "team", member_set: ["a"], bound_rule_set: "rs")
      assert Legend.legend?(legends, "team")
      refute Legend.legend?(legends, "not-a-legend")
      refute Legend.legend?(%{}, "team")
    end

    test "names/1 lists every registered legend name" do
      legends =
        %{}
        |> Legend.put("a", member_set: [], bound_rule_set: "rs_a")
        |> Legend.put("b", member_set: [], bound_rule_set: "rs_b")

      assert Enum.sort(Legend.names(legends)) == ["a", "b"]
    end
  end

  # GATE (a) — `@legend` resolves via the registry → its bound rule-set's entry
  # rule fires.
  describe "resolve/2 — symbolic handle → bound rule-set entry (GATE a)" do
    test "resolves a legend name to its entry (the bound rule-set handle)" do
      legends =
        Legend.put(%{}, "传话游戏",
          member_set: ["relay-cc"],
          bound_rule_set: "telephone",
          fold: true
        )

      assert {:ok, entry} = Legend.resolve(legends, "传话游戏")
      assert entry.bound_rule_set == "telephone"
      assert entry.name == "传话游戏"
    end

    test "resolve/2 is :error for an unknown name" do
      assert :error = Legend.resolve(%{}, "nope")
    end

    test "the entry rule of the bound rule-set is matched by mention(<legend_name>)" do
      table = EzagentDomainInstanceMessage.Routing.MentionRouting

      # The telephone rule-set entry: mention(传话游戏) → relay-cc (single-receiver).
      {:ok, _} =
        RuleStore.add(
          table,
          Matcher.mention("传话游戏"),
          ["entity://team/agent/cc_relay"],
          URI.new!("entity://system/user/admin"),
          rule_set: "telephone",
          position: 0,
          prompt_template_ref: "telephone_hop"
        )

      # second hop, higher position — NOT the entry
      {:ok, _} =
        RuleStore.add(
          table,
          Matcher.from("entity://team/agent/cc_relay"),
          ["entity://team/agent/codex_relay"],
          URI.new!("entity://system/user/admin"),
          rule_set: "telephone",
          position: 1,
          prompt_template_ref: "telephone_hop"
        )

      assert {:ok, entry_rule} = Legend.entry_rule(table, "telephone")
      # entry = lowest position in the set
      assert entry_rule.position == 0
      assert entry_rule.prompt_template_ref == "telephone_hop"
      # and its matcher is the legend mention — a SYMBOLIC string, not a URI
      assert entry_rule.matcher_data == Matcher.to_json(Matcher.mention("传话游戏"))
    end

    test "entry_rule/2 is :error for a rule-set with no rules" do
      assert :error =
               Legend.entry_rule(EzagentDomainInstanceMessage.Routing.MentionRouting, "ghost")
    end
  end

  # GATE (b) — a legend name does NOT mis-route through the URI-mention path.
  describe "mention_token/2 — legend takes precedence over a URI mention (GATE b)" do
    test "a legend name classifies as a legend token (NOT a concrete-URI mention)" do
      legends = Legend.put(%{}, "传话游戏", member_set: ["relay-cc"], bound_rule_set: "telephone")

      # The parser asks: for this typed @name, is it a legend?  If so it is
      # intercepted BEFORE the URI-mention path (it never reaches the concrete-
      # URI matcher → no silent-drop / mis-route).
      assert {:legend, "传话游戏"} = Legend.mention_token(legends, "传话游戏")
    end

    test "a non-legend name is passed through for normal URI-mention handling" do
      legends = Legend.put(%{}, "传话游戏", member_set: [], bound_rule_set: "telephone")
      assert :not_a_legend = Legend.mention_token(legends, "architect")
      assert :not_a_legend = Legend.mention_token(%{}, "anything")
    end

    test "the entry rule fires via the NORMAL Resolver path using legend_triggers" do
      # team-routing §3.6 (PR-6 redesign): the legend NAME rides the VIRTUAL
      # `Message.legend_triggers`, NOT `:mentions` (a CJK name can't be cast to
      # a URI). The rule-set entry's `mention("传话游戏")` matcher fires against
      # `legend_triggers`, so the entry's CONCRETE receiver is resolved by the
      # normal Resolver — carrying the entry's `prompt_template_ref` ctx.
      relay_cc = "entity://team/agent/cc_relay"
      session = URI.new!("session://team/default/s1")

      install_table([{Matcher.mention("传话游戏"), legend_entry([relay_cc], "telephone_hop")}])

      msg =
        Ezagent.Message.new(
          URI.new!("entity://team/user/operator"),
          %{text: "@传话游戏 start"},
          legend_triggers: ["传话游戏"]
        )

      # The symbolic legend name never touches :mentions.
      assert msg.mentions == []

      assert [{%URI{} = uri, ctx}] = Resolver.resolve_with_ctx(msg, session, [], [])

      assert URI.to_string(uri) == relay_cc
      assert ctx.prompt_template_ref == "telephone_hop"
    end

    test "a legend entry with a magic receiver ($session_members) fans out via the Resolver" do
      session = URI.new!("session://team/default/s1")
      cc = URI.new!("entity://team/agent/cc_a")
      codex = URI.new!("entity://team/agent/codex_b")
      sender = URI.new!("entity://team/user/operator")

      install_table([
        {Matcher.mention("broadcast"), legend_entry(["$session_members"], nil)}
      ])

      msg =
        Ezagent.Message.new(sender, %{text: "@broadcast hi"}, legend_triggers: ["broadcast"])

      recipients =
        Resolver.resolve(msg, session, [cc, codex, sender], [])
        |> Enum.map(&URI.to_string/1)
        |> Enum.sort()

      # The magic receiver expanded to the session members (sender excluded).
      assert recipients == Enum.sort([URI.to_string(cc), URI.to_string(codex)])
    end
  end

  # Declare a fresh, isolated RoutingRegistry ETS table and load `entries`
  # (`{matcher_tuple, value}` pairs) into it. Returns the table atom. The
  # value map mirrors the `RuleStore.load_into_registry/1` shape so the
  # Resolver's ctx threading + magic expansion run exactly as in production.
  defp install_table(entries) do
    table = String.to_atom("legend_routing_#{System.unique_integer([:positive])}")
    :ok = Ezagent.RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

    Enum.each(entries, fn {matcher, value} ->
      :ok = Ezagent.RoutingRegistry.put(table, matcher, value)
    end)

    # Point the Resolver at ONLY this isolated table for the test.
    Application.put_env(:ezagent_core, :routing_tables, [table])
    table
  end

  # The loaded-rule value shape (subset relevant to legends): receivers +
  # rule identity + prompt_template_ref (RuleStore.load_into_registry/1).
  defp legend_entry(receivers, prompt_template_ref) do
    %{
      receivers: receivers,
      applies_to_users: [],
      workspace_uri: nil,
      rule_id: System.unique_integer([:positive]),
      rule_set: "telephone",
      prompt_template_ref: prompt_template_ref
    }
  end

  # GATE (c) — fold hides folded-legend members in the list but they remain
  # first-class members (individually @-able + snapshot-able).
  describe "fold_members/2 — UI fold collapses folded legend members (GATE c)" do
    test "folded legend members collapse to a single legend entry; non-members untouched" do
      relay_cc = uri("entity://team/agent/cc_relay")
      relay_codex = uri("entity://team/agent/codex_relay")
      admin = uri("entity://system/user/admin")

      members = %{
        relay_cc => %{online: true, role_name: "relay-cc"},
        relay_codex => %{online: true, role_name: "relay-codex"},
        admin => %{online: true}
      }

      legends =
        Legend.put(%{}, "传话游戏",
          member_set: ["relay-cc", "relay-codex"],
          bound_rule_set: "telephone",
          fold: true
        )

      # Resolve member_set role_names → URIs using Chat.role_name_to_uri.
      resolver = role_resolver(members)

      folded = Legend.fold_members(members, legends, resolver)

      # The two folded relay members are collapsed into ONE legend row.
      assert Enum.any?(folded, fn
               {:legend, "传话游戏", uris} ->
                 Enum.sort(Enum.map(uris, &URI.to_string/1)) ==
                   Enum.sort([URI.to_string(relay_cc), URI.to_string(relay_codex)])

               _ ->
                 false
             end)

      # The non-folded admin member stays a first-class plain row.
      assert Enum.any?(folded, fn
               {:member, ^admin, _meta} -> true
               _ -> false
             end)

      # The collapsed relay URIs are NOT present as their own plain rows.
      refute Enum.any?(folded, fn
               {:member, u, _} -> u in [relay_cc, relay_codex]
               _ -> false
             end)
    end

    test "members stay individually addressable — the underlying members map is unchanged" do
      relay_cc = uri("entity://team/agent/cc_relay")
      members = %{relay_cc => %{online: true, role_name: "relay-cc"}}

      legends =
        Legend.put(%{}, "team", member_set: ["relay-cc"], bound_rule_set: "rs", fold: true)

      resolver = role_resolver(members)
      _ = Legend.fold_members(members, legends, resolver)

      # Folding is a presentation transform — the member is still a real,
      # individually-@-able member (the SoT map is untouched, so a concrete
      # @cc_relay / @relay-cc still resolves to it). The resolver closure (same
      # contract as Chat.role_name_to_uri/2) still resolves the role_name.
      assert resolver.("relay-cc") == relay_cc
    end

    test "a non-folded legend does NOT collapse its members" do
      relay_cc = uri("entity://team/agent/cc_relay")
      members = %{relay_cc => %{online: true, role_name: "relay-cc"}}

      legends =
        Legend.put(%{}, "team", member_set: ["relay-cc"], bound_rule_set: "rs", fold: false)

      resolver = role_resolver(members)
      folded = Legend.fold_members(members, legends, resolver)

      assert Enum.any?(folded, fn
               {:member, ^relay_cc, _} -> true
               _ -> false
             end)

      refute Enum.any?(folded, fn
               {:legend, _, _} -> true
               _ -> false
             end)
    end
  end
end
