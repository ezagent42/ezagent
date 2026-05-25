defmodule Ezagent.Routing.ResolverTest do
  @moduledoc """
  Phase 3a-step 3: Resolver tests.

  Each test declares its OWN routing table (unique per test, owned by
  the test process) and configures `Ezagent.Routing.Resolver` to query
  that table via `Application.put_env(:ezagent_core, :routing_tables, ...)`.
  This avoids conflict with the live `EzagentDomainChat.Application` which
  owns `MentionRouting` for the running app. (SessionRouting was
  retired 2026-05-25 — PR-EM-3 #317 moved its bridge responsibility
  to ExternalMirror's `external_mirror_bindings` table.)
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
      assert [] = Resolver.resolve(msg(), URI.new!("session://default/default/main"))
    end

    test "mention(X) rule fires when message mentions X — returns receivers", %{table: t} do
      target = URI.new!("entity://agent/default/test_cc-builder")
      :ok = RoutingRegistry.put(t, Matcher.mention(target), ["session://default/default/oncall"])

      result = Resolver.resolve(msg("hi", [target]), URI.new!("session://default/default/main"))
      assert result == [URI.new!("session://default/default/oncall")]
    end

    test "additive: multiple rules matching → union receivers, deduplicated", %{table: t} do
      target = URI.new!("entity://agent/default/test_X")

      :ok =
        RoutingRegistry.put(t, Matcher.mention(target), [
          "session://default/default/A",
          "session://default/default/B"
        ])

      :ok =
        RoutingRegistry.put(t, Matcher.always(), [
          "session://default/default/B",
          "session://default/default/C"
        ])

      result = Resolver.resolve(msg("hi", [target]), URI.new!("session://default/default/main"))
      uris = result |> Enum.map(&URI.to_string/1) |> Enum.sort()

      assert uris == [
               "session://default/default/A",
               "session://default/default/B",
               "session://default/default/C"
             ]
    end

    test "text_contains rule matches body", %{table: t} do
      :ok =
        RoutingRegistry.put(t, Matcher.text_contains("urgent"), [
          "session://default/default/oncall"
        ])

      assert Resolver.resolve(
               msg("server urgent down"),
               URI.new!("session://default/default/main")
             ) ==
               [URI.new!("session://default/default/oncall")]

      # No match if word absent
      assert Resolver.resolve(msg("all green"), URI.new!("session://default/default/main")) == []
    end

    test "table not declared in app env → silently skip (returns [])" do
      Application.put_env(:ezagent_core, :routing_tables, [:nonexistent_table])
      assert [] = Resolver.resolve(msg(), URI.new!("session://default/default/main"))
    end
  end
end
