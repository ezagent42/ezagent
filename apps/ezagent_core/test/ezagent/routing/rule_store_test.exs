defmodule Ezagent.Routing.RuleStoreTest do
  use ExUnit.Case
  alias Ezagent.Routing.{Matcher, RuleStore}
  alias EzagentCore.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # PR 9 §A: DefaultRules.bootstrap seeds a system_default rule into
  # MentionRouting at chat plugin boot. Tests that assert specific row
  # counts must filter to admin-source rows.
  defp admin_rules(table) do
    RuleStore.list(table)
    |> Enum.reject(&(&1.source == RuleStore.system_default_source()))
  end

  test "add → list round-trip with matcher JSON encoded" do
    table = EzagentDomainInstanceMessage.Routing.MentionRouting

    {:ok, row} =
      RuleStore.add(
        table,
        Matcher.text_contains("urgent"),
        ["session://team-alpha/default/oncall"],
        URI.new!("entity://system/user/admin")
      )

    assert row.table_name == Atom.to_string(table)
    assert row.matcher_data == %{"type" => "text_contains", "arg" => "urgent"}
    assert row.receivers == ["session://team-alpha/default/oncall"]
    assert row.created_by == "entity://system/user/admin"

    [loaded] = admin_rules(table)
    assert loaded.id == row.id
    assert {:ok, _matcher} = Matcher.from_json(loaded.matcher_data)
  end

  describe "rule-set columns (team-routing-unification §3.3)" do
    test "add persists rule_set / position / prompt_template_ref + loads them" do
      table = EzagentDomainInstanceMessage.Routing.MentionRouting

      {:ok, row} =
        RuleStore.add(
          table,
          Matcher.from(URI.new!("entity://system/agent/cc_relay")),
          ["entity://system/agent/codex_relay"],
          URI.new!("entity://system/user/admin"),
          rule_set: "telephone",
          position: 2,
          prompt_template_ref: "telephone_hop"
        )

      assert row.rule_set == "telephone"
      assert row.position == 2
      assert row.prompt_template_ref == "telephone_hop"

      loaded = Enum.find(admin_rules(table), &(&1.id == row.id))
      assert loaded.rule_set == "telephone"
      assert loaded.position == 2
      assert loaded.prompt_template_ref == "telephone_hop"
    end

    test "a rule in a named rule_set MUST be single-receiver" do
      table = EzagentDomainInstanceMessage.Routing.MentionRouting
      admin = URI.new!("entity://system/user/admin")

      assert {:error, :rule_set_requires_single_receiver} =
               RuleStore.add(
                 table,
                 Matcher.always(),
                 ["entity://system/agent/a", "entity://system/agent/b"],
                 admin,
                 rule_set: "telephone"
               )

      # single receiver in a rule_set is fine
      assert {:ok, _} =
               RuleStore.add(table, Matcher.always(), ["entity://system/agent/a"], admin,
                 rule_set: "telephone"
               )

      # standalone rule (no rule_set) keeps the multi-receiver capability
      assert {:ok, _} =
               RuleStore.add(
                 table,
                 Matcher.always(),
                 ["entity://system/agent/a", "entity://system/agent/b"],
                 admin
               )
    end

    test "load_into_registry carries rule_id + rule_set + prompt_template_ref into the value" do
      table = String.to_atom("rule_store_ruleset_test_#{System.unique_integer([:positive])}")
      :ok = Ezagent.RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

      {:ok, row} =
        RuleStore.add(
          table,
          Matcher.from(URI.new!("entity://system/agent/cc_relay")),
          ["entity://system/agent/codex_relay"],
          URI.new!("entity://system/user/admin"),
          rule_set: "telephone",
          prompt_template_ref: "telephone_hop"
        )

      :ok = RuleStore.load_into_registry(table)

      assert [{_matcher, value}] = Ezagent.RoutingRegistry.list_all(table)
      assert value.rule_id == row.id
      assert value.rule_set == "telephone"
      assert value.prompt_template_ref == "telephone_hop"
    end

    test "update_receivers must not widen a rule_set rule to multi-receiver" do
      table = EzagentDomainInstanceMessage.Routing.MentionRouting
      admin = URI.new!("entity://system/user/admin")

      {:ok, row} =
        RuleStore.add(table, Matcher.always(), ["entity://system/agent/a"], admin,
          rule_set: "telephone"
        )

      assert {:error, :rule_set_requires_single_receiver} =
               RuleStore.update_receivers(
                 row.id,
                 ["entity://system/agent/a", "entity://system/agent/b"],
                 true
               )

      # a single-receiver update is fine
      assert :ok = RuleStore.update_receivers(row.id, ["entity://system/agent/c"], true)
    end
  end

  test "list scoped by table name — other tables don't leak" do
    # 2026-05-25 — was MentionRouting + SessionRouting; SessionRouting
    # was retired (PR-EM-3 #317 moved its bridge to ExternalMirror).
    # The RuleStore is a generic per-table store keyed by string, so
    # the "no leak" property is exercised with a synthetic second
    # table atom — equivalent test surface, no defunct module.
    other_table = :"rule_store_test_other_#{System.unique_integer([:positive])}"

    {:ok, _} =
      RuleStore.add(
        EzagentDomainInstanceMessage.Routing.MentionRouting,
        Matcher.always(),
        ["session://team-alpha/default/a"],
        nil
      )

    {:ok, _} =
      RuleStore.add(
        other_table,
        Matcher.from("entity://team-alpha/agent/test_x"),
        ["session://team-alpha/default/b"],
        nil
      )

    assert length(admin_rules(EzagentDomainInstanceMessage.Routing.MentionRouting)) == 1
    assert length(admin_rules(other_table)) == 1
  end

  test "delete removes by id" do
    {:ok, row} =
      RuleStore.add(
        EzagentDomainInstanceMessage.Routing.MentionRouting,
        Matcher.always(),
        ["session://team-alpha/default/x"],
        nil
      )

    assert :ok = RuleStore.delete(row.id)
    assert {:error, :not_found} = RuleStore.delete(row.id)
    assert [] = admin_rules(EzagentDomainInstanceMessage.Routing.MentionRouting)
  end

  test "URI struct receiver gets serialized to string" do
    {:ok, row} =
      RuleStore.add(
        EzagentDomainInstanceMessage.Routing.MentionRouting,
        Matcher.always(),
        [URI.new!("session://team-alpha/default/x"), URI.new!("session://team-alpha/default/y")],
        URI.new!("entity://system/user/admin")
      )

    assert row.receivers == ["session://team-alpha/default/x", "session://team-alpha/default/y"]
  end
end
