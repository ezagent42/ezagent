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
    table = EzagentDomainChat.Routing.MentionRouting

    {:ok, row} =
      RuleStore.add(
        table,
        Matcher.text_contains("urgent"),
        ["session://default/team-alpha/oncall"],
        URI.new!("entity://user/system/admin")
      )

    assert row.table_name == Atom.to_string(table)
    assert row.matcher_data == %{"type" => "text_contains", "arg" => "urgent"}
    assert row.receivers == ["session://default/team-alpha/oncall"]
    assert row.created_by == "entity://user/system/admin"

    [loaded] = admin_rules(table)
    assert loaded.id == row.id
    assert {:ok, _matcher} = Matcher.from_json(loaded.matcher_data)
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
        EzagentDomainChat.Routing.MentionRouting,
        Matcher.always(),
        ["session://default/team-alpha/a"],
        nil
      )

    {:ok, _} =
      RuleStore.add(
        other_table,
        Matcher.from("entity://agent/team-alpha/test_x"),
        ["session://default/team-alpha/b"],
        nil
      )

    assert length(admin_rules(EzagentDomainChat.Routing.MentionRouting)) == 1
    assert length(admin_rules(other_table)) == 1
  end

  test "delete removes by id" do
    {:ok, row} =
      RuleStore.add(
        EzagentDomainChat.Routing.MentionRouting,
        Matcher.always(),
        ["session://default/team-alpha/x"],
        nil
      )

    assert :ok = RuleStore.delete(row.id)
    assert {:error, :not_found} = RuleStore.delete(row.id)
    assert [] = admin_rules(EzagentDomainChat.Routing.MentionRouting)
  end

  test "URI struct receiver gets serialized to string" do
    {:ok, row} =
      RuleStore.add(
        EzagentDomainChat.Routing.MentionRouting,
        Matcher.always(),
        [URI.new!("session://default/team-alpha/x"), URI.new!("session://default/team-alpha/y")],
        URI.new!("entity://user/system/admin")
      )

    assert row.receivers == ["session://default/team-alpha/x", "session://default/team-alpha/y"]
  end
end
