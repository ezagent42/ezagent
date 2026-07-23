defmodule EzagentDomainInstanceMessage.E2E.Category10.Scenario22RoutingCRUDTest do
  @moduledoc """
  E2E scenario 22 — Routing rule CRUD + precedence.

  Cross-references `docs/scenarios/22-routing-crud/scenario.md`.

  Exercises the full life-cycle of an admin-authored routing rule:

  - Add a rule via the `Ezagent.ActionSet.Routing` dispatch path.
  - List confirms the new rule is present.
  - The rule loads into the live `RoutingRegistry` ETS table
    (`load_into_registry/1` runs after each mutation per PR #127).
  - Disable + re-enable flips the live registry contents.
  - Delete removes the row + ETS entry.
  - The `system_default` rule (`always → [$session_users, $mentions]`)
    is **disable-able** but NEVER deletable (PR #120, Decision #120).

  Verification surface (per `feedback_esr_e2e_standards`): dispatch +
  RuleStore + RoutingRegistry chokepoints. The `/admin/routing` LV
  page reads from the same `RuleStore` API, so structural-level pinning
  here covers both LV and CLI surfaces. LV-specific rendering is
  covered separately by sibling `routing_live_test.exs`.

  Scenario `scenario: "22-routing-crud"` (moduletag).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, RoutingRegistry, Routing.Matcher, Routing.RuleStore}
  alias EzagentDomainInstanceMessage.Routing.MentionRouting

  @moduletag scenario: "22-routing-crud"

  @table MentionRouting

  defp admin_ctx(target) do
    admin = Ezagent.Entity.User.admin_uri()

    %{
      caller: admin,
      authenticated_principal: admin,
      caps: MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(target, admin)]),
      reply: {:caller_inbox, self()}
    }
  end

  defp global_routing_target(action) do
    Ezagent.URI.new!(
      "#{URI.to_string(Ezagent.Entity.System.routing_default_uri())}?action=routing.#{action}"
    )
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # #52 Mode-B fix: `system://routing/default` is no longer eager-spawned
  # at boot in `:test`. These tests dispatch `routing.add_rule` / `delete_rule`
  # to it, so spawn it inside the DataCase-checked-out owner and allow its
  # pid onto the connection. Exercises the demand-spawn path. (greppable:
  # routing_default_uri)
  setup do
    uri = Ezagent.Entity.System.routing_default_uri()

    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} ->
        :ok = DynamicSupervisor.terminate_child(Ezagent.Core.SingletonSupervisor, pid)

      :error ->
        :ok
    end

    {:ok, pid} = Ezagent.SpawnRegistry.spawn(uri)
    _ = Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), pid)
    :ok
  end

  describe "add_rule via Behavior.Routing dispatch" do
    test "admin can add a mention-matcher rule + it appears in list" do
      receiver = "entity://team-alpha/agent/echo_#{uniq("x")}"
      matcher = Matcher.mention(receiver)

      assert {:ok, %{id: rule_id}} =
               Invocation.dispatch(%Invocation{
                 origin: :trusted_internal,
                 target: global_routing_target("add_rule"),
                 mode: :call,
                 args: %{
                   table: @table,
                   matcher_json: Matcher.to_json(matcher),
                   receivers: [receiver]
                 },
                 ctx: admin_ctx(global_routing_target("add_rule"))
               })

      assert is_integer(rule_id), "add_rule MUST return the inserted row id"

      # Listing the table includes the new rule.
      rules = RuleStore.list(@table)
      assert Enum.any?(rules, fn r -> r.id == rule_id end)
    end

    test "newly-added rule serializes Matcher AST via to_json round-trip" do
      receiver = "entity://team-alpha/agent/echo_#{uniq("rt")}"
      matcher = Matcher.text_contains("urgent")

      {:ok, %{id: rule_id}} =
        Invocation.dispatch(%Invocation{
          origin: :trusted_internal,
          target: global_routing_target("add_rule"),
          mode: :call,
          args: %{
            table: @table,
            matcher_json: Matcher.to_json(matcher),
            receivers: [receiver]
          },
          ctx: admin_ctx(global_routing_target("add_rule"))
        })

      [stored] = Enum.filter(RuleStore.list(@table), &(&1.id == rule_id))

      assert stored.matcher_data == %{"type" => "text_contains", "arg" => "urgent"},
             "matcher_data MUST round-trip Matcher.to_json/1 exactly"

      assert {:ok, ^matcher} = Matcher.from_json(stored.matcher_data),
             "from_json(to_json(m)) MUST equal m — 5-leaf grammar invariant"
    end

    test "5-leaf grammar — all matcher types serialize + parse identically" do
      # Per PR #118 / Decision #118 the routing grammar has 5 leaves +
      # 3 combinators. Pin them all to prevent silent grammar drift.
      mention_uri = "entity://team-alpha/agent/echo_a"
      from_uri = "entity://team-alpha/user/alice"

      cases = [
        {Matcher.mention(mention_uri), %{"type" => "mention", "arg" => mention_uri}},
        {Matcher.from(from_uri), %{"type" => "from", "arg" => from_uri}},
        {Matcher.text_contains("hello"), %{"type" => "text_contains", "arg" => "hello"}},
        {Matcher.always(), %{"type" => "always"}}
      ]

      for {matcher, expected_json} <- cases do
        assert Matcher.to_json(matcher) == expected_json,
               "matcher #{inspect(matcher)} JSON-encoded MUST equal #{inspect(expected_json)}"

        assert {:ok, ^matcher} = Matcher.from_json(expected_json),
               "matcher #{inspect(matcher)} MUST round-trip through from_json"
      end
    end

    test "combinators (and / or / not) compose leaves correctly" do
      a = Matcher.mention("entity://team-alpha/agent/echo_a")
      b = Matcher.text_contains("urgent")

      and_matcher = Matcher.all_of([a, b])
      or_matcher = Matcher.any_of([a, b])
      not_matcher = Matcher.negate(a)

      for m <- [and_matcher, or_matcher, not_matcher] do
        json = Matcher.to_json(m)

        assert {:ok, ^m} = Matcher.from_json(json),
               "combinator #{inspect(m)} MUST round-trip JSON encoding"
      end
    end
  end

  describe "disable + enable" do
    test "disable removes the rule from the live ETS table; enable re-adds" do
      receiver = "entity://team-alpha/agent/echo_#{uniq("de")}"
      matcher = Matcher.text_contains("dis_marker_#{uniq("x")}")

      {:ok, %{id: rule_id}} =
        Invocation.dispatch(%Invocation{
          origin: :trusted_internal,
          target: global_routing_target("add_rule"),
          mode: :call,
          args: %{
            table: @table,
            matcher_json: Matcher.to_json(matcher),
            receivers: [receiver]
          },
          ctx: admin_ctx(global_routing_target("add_rule"))
        })

      # After add, the rule is in the live ETS table.
      ets_before_disable = RoutingRegistry.list_all(@table)

      assert Enum.any?(ets_before_disable, &matcher_match?(&1, matcher)),
             "after add, rule MUST be live in RoutingRegistry"

      assert {:ok, %{disabled: ^rule_id}} =
               Invocation.dispatch(%Invocation{
                 origin: :trusted_internal,
                 target: global_routing_target("disable_rule"),
                 mode: :call,
                 args: %{table: @table, id: rule_id},
                 ctx: admin_ctx(global_routing_target("disable_rule"))
               })

      # `load_into_registry/1` filters `enabled: true` only — the disabled
      # rule should be GONE from ETS.
      ets_after_disable = RoutingRegistry.list_all(@table)

      refute Enum.any?(ets_after_disable, &matcher_match?(&1, matcher)),
             "disabled rule MUST be absent from live ETS table after RuleStore.load_into_registry"

      # Re-enable.
      assert {:ok, %{enabled: ^rule_id}} =
               Invocation.dispatch(%Invocation{
                 origin: :trusted_internal,
                 target: global_routing_target("enable_rule"),
                 mode: :call,
                 args: %{table: @table, id: rule_id},
                 ctx: admin_ctx(global_routing_target("enable_rule"))
               })

      ets_after_enable = RoutingRegistry.list_all(@table)

      assert Enum.any?(ets_after_enable, &matcher_match?(&1, matcher)),
             "re-enabled rule MUST be live again"
    end
  end

  describe "delete_rule" do
    test "delete removes the rule + clears its ETS entry" do
      receiver = "entity://team-alpha/agent/echo_#{uniq("del")}"
      matcher = Matcher.text_contains("del_marker_#{uniq("y")}")

      {:ok, %{id: rule_id}} =
        Invocation.dispatch(%Invocation{
          origin: :trusted_internal,
          target: global_routing_target("add_rule"),
          mode: :call,
          args: %{
            table: @table,
            matcher_json: Matcher.to_json(matcher),
            receivers: [receiver]
          },
          ctx: admin_ctx(global_routing_target("add_rule"))
        })

      assert {:ok, %{deleted: ^rule_id}} =
               Invocation.dispatch(%Invocation{
                 origin: :trusted_internal,
                 target: global_routing_target("delete_rule"),
                 mode: :call,
                 args: %{table: @table, id: rule_id},
                 ctx: admin_ctx(global_routing_target("delete_rule"))
               })

      # Row gone from DB.
      refute Enum.any?(RuleStore.list(@table), &(&1.id == rule_id)),
             "rule MUST be gone from RuleStore.list after delete"

      # ETS entry gone.
      ets_after_delete = RoutingRegistry.list_all(@table)

      refute Enum.any?(ets_after_delete, &matcher_match?(&1, matcher)),
             "rule MUST be gone from live ETS after delete"
    end
  end

  describe "system_default protection (PR #120 / Decision #120)" do
    test "system_default rule cannot be deleted via RuleStore.delete/1" do
      [default] =
        RuleStore.list(@table)
        |> Enum.filter(&(&1.source == RuleStore.system_default_source()))

      assert {:error, :cannot_delete_system_default} = RuleStore.delete(default.id),
             "system_default rule MUST refuse direct delete — Decision #120"

      # Still present.
      assert [^default] =
               RuleStore.list(@table)
               |> Enum.filter(&(&1.source == RuleStore.system_default_source()))
    end

    test "system_default rule CAN be disabled (admin opt-out path)" do
      [default] =
        RuleStore.list(@table)
        |> Enum.filter(&(&1.source == RuleStore.system_default_source()))

      assert :ok = RuleStore.disable(default.id),
             "disabling a system_default rule is admin's opt-out path"

      [refetched] =
        RuleStore.list(@table)
        |> Enum.filter(&(&1.source == RuleStore.system_default_source()))

      refute refetched.enabled,
             "system_default rule's enabled flag MUST flip to false after disable"

      # Restore for downstream tests.
      :ok = RuleStore.enable(default.id)
    end

    test "force: true bypasses system_default protection (operator escape hatch)" do
      # Use a one-off, short-lived system_default fixture so we don't
      # have to re-bootstrap the production one. The opts API is the
      # contract under test.
      {:ok, row} =
        RuleStore.add(
          @table,
          Matcher.text_contains("force_marker_#{uniq("f")}"),
          ["entity://team-alpha/agent/echo_force"],
          nil,
          source: RuleStore.system_default_source()
        )

      assert {:error, :cannot_delete_system_default} = RuleStore.delete(row.id)

      assert :ok = RuleStore.delete(row.id, force: true),
             "force: true MUST bypass the system_default delete protection"

      refute Enum.any?(RuleStore.list(@table), &(&1.id == row.id))
    end
  end

  describe "DefaultRules.bootstrap idempotency (boot-ordering invariant)" do
    test "bootstrap can be re-run without duplicating system_default rows" do
      before_count =
        RuleStore.list(@table)
        |> Enum.count(&(&1.source == RuleStore.system_default_source()))

      :ok = EzagentDomainInstanceMessage.DefaultRules.bootstrap()
      :ok = EzagentDomainInstanceMessage.DefaultRules.bootstrap()

      after_count =
        RuleStore.list(@table)
        |> Enum.count(&(&1.source == RuleStore.system_default_source()))

      assert after_count == before_count,
             "bootstrap MUST be idempotent — repeat invocation MUST NOT duplicate system_default rows"
    end
  end

  # --- helpers -----------------------------------------------------

  # ETS entries from RuleStore.load_into_registry/1 are
  # `{matcher_tuple, %{receivers: _, applies_to_users: _, workspace_uri: _}}`.
  defp matcher_match?({stored_matcher, _value}, expected_matcher),
    do: stored_matcher == expected_matcher
end
