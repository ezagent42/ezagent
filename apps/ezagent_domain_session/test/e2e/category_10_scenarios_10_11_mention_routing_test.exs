defmodule EzagentDomainInstanceMessage.E2E.Category10.Scenarios10_11_MentionRoutingTest do
  @moduledoc """
  E2E scenarios 10 + 11 — mention-gated routing + cross-session leak.

  - Scenario 10 (`docs/scenarios/10-mention-gated-routing/scenario.md`):
    `@`-mentioned agents receive `chat.receive`; non-mentioned agents
    do NOT. The system-default rule `always → [$session_users, $mentions]`
    + the `$mentions` magic token enforce this.

  - Scenario 11 (`docs/scenarios/11-cross-session-mention-rejected/scenario.md`):
    Mentioning an agent NOT in the current session's members list
    delivers nothing — the cross-session leak guard. The catalog flags
    scenario 11 as ⚠️ "no dedicated test"; this file is that test.

  Both scenarios exercise `Ezagent.Routing.Resolver.resolve/4` at the
  pure-function level. Production dispatch goes through `Behavior.Session`'s
  `:send` action, but the routing decision IS made by Resolver — pinning
  it here covers the security-critical property without requiring a
  full Session GenServer + Audit writer setup. Sibling integration
  test `mention_gated_routing_test.exs` already covers the live dispatch
  surface end-to-end; this file is the matcher-level invariant gate.

  Per `feedback_completion_requires_invariant_test`: an invariant test
  for cross-session mention rejection is the missing piece per the
  scenario 11 catalog entry.

  Scenarios `scenario: "10-mention-gated-routing"` + `scenario:
  "11-cross-session-mention-rejected"` (per-test moduletag).
  """

  use ExUnit.Case, async: false

  alias Ezagent.{Message, RoutingRegistry, Routing.Matcher, Routing.Resolver}

  @workspace URI.new!("workspace://team-alpha")
  @session_a URI.new!("session://team-alpha/default/sess_a")
  @session_b URI.new!("session://team-alpha/default/sess_b")
  @admin URI.new!("entity://team-alpha/user/admin")
  @alice URI.new!("entity://team-alpha/user/alice")
  @echo_1 URI.new!("entity://team-alpha/agent/echo_1")
  @echo_2 URI.new!("entity://team-alpha/agent/echo_2")

  defp uniq(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp install_default_rule_table do
    table = String.to_atom("e2e_mention_routing_#{uniq("t")}")
    :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

    :ok =
      RoutingRegistry.put(
        table,
        Matcher.always(),
        %{
          receivers: [Resolver.session_users_token(), Resolver.mentions_token()],
          applies_to_users: [],
          workspace_uri: nil
        }
      )

    original = Application.get_env(:ezagent_core, :routing_tables)
    Application.put_env(:ezagent_core, :routing_tables, [table])

    on_exit(fn ->
      if original do
        Application.put_env(:ezagent_core, :routing_tables, original)
      else
        Application.delete_env(:ezagent_core, :routing_tables)
      end
    end)

    table
  end

  defp build_msg(sender, text, mentions) do
    %Message{
      id: "test-#{System.unique_integer([:positive])}",
      sender: sender,
      body: %{text: text, attachments: []},
      mentions: mentions,
      ref_id: nil,
      inserted_at: ~U[2026-05-28 00:00:00.000000Z]
    }
  end

  describe "Scenario 10 — mention-gated routing in-session" do
    @describetag scenario: "10-mention-gated-routing"

    test "non-mention message fans out to session_users only (no agent fan-out)" do
      install_default_rule_table()

      members = [@admin, @alice, @echo_1, @echo_2]
      msg = build_msg(@admin, "hi everyone", [])

      recipients =
        Resolver.resolve(msg, @session_a, members, workspace_uri: @workspace)

      recipient_strs = Enum.map(recipients, &URI.to_string/1) |> Enum.sort()

      # Only the OTHER User-Kind member (alice) receives via $session_users.
      # Agents do NOT receive without an explicit mention.
      assert recipient_strs == [URI.to_string(@alice)],
             "non-mention message MUST deliver to $session_users only; agents must NOT fan out (mention-gated)"
    end

    test "mention delivers ONLY to the mentioned agent (other agents excluded)" do
      install_default_rule_table()

      members = [@admin, @echo_1, @echo_2]
      msg = build_msg(@admin, "hi @echo_1 only", [@echo_1])

      recipients =
        Resolver.resolve(msg, @session_a, members, workspace_uri: @workspace)

      recipient_strs = Enum.map(recipients, &URI.to_string/1) |> Enum.sort()

      assert URI.to_string(@echo_1) in recipient_strs,
             "mentioned agent MUST receive"

      refute URI.to_string(@echo_2) in recipient_strs,
             "non-mentioned agent MUST NOT receive — mention-gated routing core invariant"
    end

    test "multi-mention delivers to ALL mentioned agents (and ONLY them)" do
      install_default_rule_table()

      members = [@admin, @echo_1, @echo_2]
      msg = build_msg(@admin, "hi @echo_1 @echo_2", [@echo_1, @echo_2])

      recipients =
        Resolver.resolve(msg, @session_a, members, workspace_uri: @workspace)

      recipient_strs = Enum.map(recipients, &URI.to_string/1) |> MapSet.new()

      assert MapSet.member?(recipient_strs, URI.to_string(@echo_1))
      assert MapSet.member?(recipient_strs, URI.to_string(@echo_2))
    end

    test "sender is excluded from recipients (no self-receive)" do
      install_default_rule_table()

      # Admin mentions themselves — must still be excluded.
      members = [@admin, @alice]
      msg = build_msg(@admin, "@admin self-mention", [@admin])

      recipients =
        Resolver.resolve(msg, @session_a, members, workspace_uri: @workspace)

      refute URI.to_string(@admin) in Enum.map(recipients, &URI.to_string/1),
             "sender MUST be excluded from recipients — no self-receive"
    end

    test "no members + system_default rule → no recipients" do
      install_default_rule_table()

      msg = build_msg(@admin, "alone", [])
      recipients = Resolver.resolve(msg, @session_a, [], workspace_uri: @workspace)

      assert recipients == [],
             "no members → no recipients — fan-out MUST come from the explicit member list, not magic"
    end
  end

  describe "Scenario 11 — cross-session mention rejected" do
    @describetag scenario: "11-cross-session-mention-rejected"

    test "mentioning an agent NOT in current session's members → 0 recipients" do
      install_default_rule_table()

      # admin is in sess_b; echo_1 is a member of sess_a only.
      sess_b_members = [@admin]
      msg = build_msg(@admin, "@echo_1 hello from b", [@echo_1])

      recipients =
        Resolver.resolve(msg, @session_b, sess_b_members, workspace_uri: @workspace)

      refute URI.to_string(@echo_1) in Enum.map(recipients, &URI.to_string/1),
             "cross-session mention MUST be dropped — the routing leak guard"

      # Total recipients = 0 (admin is sender, and echo_1 isn't a member).
      assert recipients == [],
             "cross-session mention scenario yields ZERO recipients — security property"
    end

    test "if mentioned agent IS a member of current session, it DOES receive (positive control)" do
      install_default_rule_table()

      # echo_1 is a member of sess_a — the mention should deliver.
      sess_a_members = [@admin, @echo_1]
      msg = build_msg(@admin, "@echo_1 hello", [@echo_1])

      recipients =
        Resolver.resolve(msg, @session_a, sess_a_members, workspace_uri: @workspace)

      assert URI.to_string(@echo_1) in Enum.map(recipients, &URI.to_string/1),
             "in-session mention MUST deliver — positive control"
    end

    test "cross-workspace member URI in mentions is also dropped" do
      install_default_rule_table()

      # Echo from another workspace — even if (incorrectly) listed in members,
      # the workspace-segment match in valid_member?/2 must reject.
      other_ws_echo = URI.new!("entity://other-workspace/agent/echo_evil")
      sess_a_members = [@admin, other_ws_echo]
      msg = build_msg(@admin, "@evil cross", [other_ws_echo])

      recipients =
        Resolver.resolve(msg, @session_a, sess_a_members, workspace_uri: @workspace)

      refute URI.to_string(other_ws_echo) in Enum.map(recipients, &URI.to_string/1),
             "cross-workspace mention MUST be dropped — workspace boundary is structural"
    end

    test "session URI in mentions (cross-session route) is dropped from $mentions" do
      install_default_rule_table()

      # A session:// URI passed as a mention — $mentions expansion filters
      # cross-session URIs (a session:// candidate naming a session OTHER
      # than current_session_uri is dropped).
      sess_a_members = [@admin]
      msg = build_msg(@admin, "@<other-session>", [@session_b])

      recipients =
        Resolver.resolve(msg, @session_a, sess_a_members, workspace_uri: @workspace)

      refute URI.to_string(@session_b) in Enum.map(recipients, &URI.to_string/1),
             "session URI in mentions MUST NOT be a cross-session route — $mentions trust boundary"
    end
  end

  describe "current session URI is excluded (recursion guard)" do
    @describetag scenario: "10-mention-gated-routing"

    test "Resolver excludes current_session_uri to prevent dispatch loop" do
      table = String.to_atom("recur_test_#{uniq("t")}")
      :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

      # Pathological rule routing to the current session — Resolver MUST drop it.
      :ok = RoutingRegistry.put(table, Matcher.always(), [URI.to_string(@session_a)])

      original = Application.get_env(:ezagent_core, :routing_tables)
      Application.put_env(:ezagent_core, :routing_tables, [table])

      on_exit(fn ->
        if original do
          Application.put_env(:ezagent_core, :routing_tables, original)
        else
          Application.delete_env(:ezagent_core, :routing_tables)
        end
      end)

      msg = build_msg(@admin, "loop test", [])
      recipients = Resolver.resolve(msg, @session_a, [], workspace_uri: @workspace)

      refute URI.to_string(@session_a) in Enum.map(recipients, &URI.to_string/1),
             "Resolver MUST exclude current_session_uri — recursion guard"
    end
  end
end
