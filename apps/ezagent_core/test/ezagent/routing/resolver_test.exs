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
    Message.new(URI.new!("entity://user/system/admin"), %{text: text, attachments: []},
      mentions: mentions
    )
  end

  describe "resolve/2" do
    test "returns [] when no rule matches → caller falls through to in-session default" do
      assert [] = Resolver.resolve(msg(), URI.new!("session://default/system/main"))
    end

    test "mention(X) rule fires when message mentions X — returns receivers", %{table: t} do
      target = URI.new!("entity://agent/team-alpha/test_cc-builder")

      :ok =
        RoutingRegistry.put(t, Matcher.mention(target), ["session://default/team-alpha/oncall"])

      result = Resolver.resolve(msg("hi", [target]), URI.new!("session://default/system/main"))
      assert result == [URI.new!("session://default/team-alpha/oncall")]
    end

    test "additive: multiple rules matching → union receivers, deduplicated", %{table: t} do
      target = URI.new!("entity://agent/team-alpha/test_X")

      :ok =
        RoutingRegistry.put(t, Matcher.mention(target), [
          "session://default/team-alpha/A",
          "session://default/team-alpha/B"
        ])

      :ok =
        RoutingRegistry.put(t, Matcher.always(), [
          "session://default/team-alpha/B",
          "session://default/team-alpha/C"
        ])

      result = Resolver.resolve(msg("hi", [target]), URI.new!("session://default/system/main"))
      uris = result |> Enum.map(&URI.to_string/1) |> Enum.sort()

      assert uris == [
               "session://default/team-alpha/A",
               "session://default/team-alpha/B",
               "session://default/team-alpha/C"
             ]
    end

    test "text_contains rule matches body", %{table: t} do
      :ok =
        RoutingRegistry.put(t, Matcher.text_contains("urgent"), [
          "session://default/team-alpha/oncall"
        ])

      assert Resolver.resolve(
               msg("server urgent down"),
               URI.new!("session://default/system/main")
             ) ==
               [URI.new!("session://default/team-alpha/oncall")]

      # No match if word absent
      assert Resolver.resolve(msg("all green"), URI.new!("session://default/system/main")) == []
    end

    test "table not declared in app env → silently skip (returns [])" do
      Application.put_env(:ezagent_core, :routing_tables, [:nonexistent_table])
      assert [] = Resolver.resolve(msg(), URI.new!("session://default/system/main"))
    end
  end

  describe "resolve_with_ctx/4 (matched-rule context, §3.5)" do
    test "returns ctx with the matched rule's prompt_template_ref + rule_id", %{table: t} do
      :ok =
        RoutingRegistry.put(t, Matcher.always(), %{
          receivers: ["session://default/team-alpha/oncall"],
          applies_to_users: [],
          workspace_uri: nil,
          rule_id: 42,
          rule_set: "telephone",
          prompt_template_ref: "telephone_hop"
        })

      assert [{uri, ctx}] =
               Resolver.resolve_with_ctx(msg(), URI.new!("session://default/system/main"), [], [])

      assert URI.to_string(uri) == "session://default/team-alpha/oncall"
      assert ctx.prompt_template_ref == "telephone_hop"
      assert ctx.rule_id == 42
      assert ctx.rule_set == "telephone"
    end

    test "ctx is nil for a legacy plain-list rule", %{table: t} do
      :ok = RoutingRegistry.put(t, Matcher.always(), ["session://default/team-alpha/oncall"])

      assert [{_uri, nil}] =
               Resolver.resolve_with_ctx(msg(), URI.new!("session://default/system/main"), [], [])
    end

    test "resolve/4 still returns bare [URI] (back-compat — delegates to resolve_with_ctx)",
         %{table: t} do
      :ok = RoutingRegistry.put(t, Matcher.always(), ["session://default/team-alpha/oncall"])

      assert Resolver.resolve(msg(), URI.new!("session://default/system/main"), [], []) ==
               [URI.new!("session://default/team-alpha/oncall")]
    end

    test "duplicate recipient from two rules → lower rule_id ctx wins (deterministic)",
         %{table: t} do
      recv = "session://default/team-alpha/oncall"
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
                 URI.new!("session://default/system/main"),
                 [],
                 []
               )

      assert URI.to_string(uri) == recv
      assert ctx.rule_id == 1
      assert ctx.prompt_template_ref == "from_rule_1"
    end
  end
end
