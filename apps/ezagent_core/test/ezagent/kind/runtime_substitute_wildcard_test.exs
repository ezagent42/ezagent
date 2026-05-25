defmodule Ezagent.Kind.RuntimeSubstituteWildcardTest do
  @moduledoc """
  Unit tests for `Ezagent.Kind.Runtime.substitute_wildcard_kind/2` —
  the wildcard-kind substitution helper introduced in PR-CC-2b
  (SPEC caps-cleanup-v1 §5.3).

  Behaviors registered against multiple Kinds (Routing on
  Workspace+Session+System, Chat `:receive` on User+Agent, Identity on
  User+Agent, IdentityAdmin on User+Agent) declare the kind segment of
  their required cap as `*`. At dispatch step 5.5 we substitute that
  `*` with the target Kind's actual `type_name()` so a holder with a
  concrete-kind cap (`session.chat.receive`) authorizes against the
  wildcard-needed cap (`*.chat.receive`).

  This is the "regression earns a unit test" gate per memory
  `feedback_e2e_failure_earns_unit_test` — the wildcard substitution
  surfaced in PR-CC-2a's subagent self-review; this test locks the
  semantics so a future "simplification" doesn't break it.
  """
  use ExUnit.Case, async: true

  # Module fixtures with declared type_name/0 so the substitution
  # helper has something to read.
  defmodule SessionKindStub do
    def type_name, do: :session
  end

  defmodule WorkspaceKindStub do
    def type_name, do: :workspace
  end

  defmodule SystemKindStub do
    def type_name, do: :system
  end

  defmodule UserKindStub do
    def type_name, do: :user
  end

  defmodule AgentKindStub do
    def type_name, do: :agent
  end

  describe "substitute_wildcard_kind/2 (PR-CC-2b §5.3)" do
    test "substitutes `*` kind segment with target Kind's type_name (Routing case)" do
      # Routing declared as *.routing.add_rule — must substitute when
      # dispatched against any of Workspace / Session / System Kinds.
      assert "workspace.routing.add_rule" ==
               Ezagent.Kind.Runtime.substitute_wildcard_kind(
                 "*.routing.add_rule",
                 WorkspaceKindStub
               )

      assert "session.routing.add_rule" ==
               Ezagent.Kind.Runtime.substitute_wildcard_kind(
                 "*.routing.add_rule",
                 SessionKindStub
               )

      assert "system.routing.add_rule" ==
               Ezagent.Kind.Runtime.substitute_wildcard_kind(
                 "*.routing.add_rule",
                 SystemKindStub
               )
    end

    test "substitutes `*.chat.receive` for User/Agent (Chat:receive case)" do
      assert "user.chat.receive" ==
               Ezagent.Kind.Runtime.substitute_wildcard_kind(
                 "*.chat.receive",
                 UserKindStub
               )

      assert "agent.chat.receive" ==
               Ezagent.Kind.Runtime.substitute_wildcard_kind(
                 "*.chat.receive",
                 AgentKindStub
               )
    end

    test "substitutes `*.identity.list_caps` for User/Agent (Identity case)" do
      assert "user.identity.list_caps" ==
               Ezagent.Kind.Runtime.substitute_wildcard_kind(
                 "*.identity.list_caps",
                 UserKindStub
               )

      assert "agent.identity.list_caps" ==
               Ezagent.Kind.Runtime.substitute_wildcard_kind(
                 "*.identity.list_caps",
                 AgentKindStub
               )
    end

    test "leaves cap strings with no `*` kind segment unchanged" do
      assert "session.chat.send" ==
               Ezagent.Kind.Runtime.substitute_wildcard_kind(
                 "session.chat.send",
                 SessionKindStub
               )

      assert "user.api_keys.list_api_keys" ==
               Ezagent.Kind.Runtime.substitute_wildcard_kind(
                 "user.api_keys.list_api_keys",
                 UserKindStub
               )
    end

    test "leaves the `*` wildcard if it appears in the behavior or action segments" do
      # `session.*` granted is a holder's broad authority — must NOT be
      # rewritten when it appears in a needed cap (it normally wouldn't
      # appear in `required_caps/0` declarations, but the helper must
      # not corrupt it if it does).
      assert "session.*" ==
               Ezagent.Kind.Runtime.substitute_wildcard_kind(
                 "session.*",
                 SessionKindStub
               )

      assert "session.chat.*" ==
               Ezagent.Kind.Runtime.substitute_wildcard_kind(
                 "session.chat.*",
                 SessionKindStub
               )
    end

    test "leaves the allowlisted special `*` admin cap unchanged" do
      # The single-segment `*` is the admin allowlisted special per
      # Ezagent.Cap — it must NOT be rewritten to `<kind>` because that
      # would lose its admin-anything semantics.
      assert "*" ==
               Ezagent.Kind.Runtime.substitute_wildcard_kind(
                 "*",
                 SessionKindStub
               )
    end

    test "handles 2-segment behavior-level cap with wildcard kind" do
      # `*.chat` (behavior-level cap, no action) should also substitute
      # the kind segment.
      assert "session.chat" ==
               Ezagent.Kind.Runtime.substitute_wildcard_kind(
                 "*.chat",
                 SessionKindStub
               )
    end
  end
end
