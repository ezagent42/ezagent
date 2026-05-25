defmodule Ezagent.CapTest do
  use ExUnit.Case, async: true

  alias Ezagent.Cap

  describe "matches?/2 — admin wildcard" do
    test "`*` matches anything" do
      assert Cap.matches?("*", "session.chat.send")
      assert Cap.matches?("*", "session.chat")
      assert Cap.matches?("*", "session.chat.send@session://default/team/main")
      assert Cap.matches?("*", "user.identity.grant_cap")
      assert Cap.matches?("*", "*")
    end
  end

  describe "matches?/2 — exact match" do
    test "identical strings match" do
      assert Cap.matches?("session.chat.send", "session.chat.send")
      assert Cap.matches?("session.chat", "session.chat")
      assert Cap.matches?(
               "session.chat.send@session://default/team/main",
               "session.chat.send@session://default/team/main"
             )
    end

    test "different action denies" do
      refute Cap.matches?("session.chat.send", "session.chat.join")
    end

    test "different behavior denies" do
      refute Cap.matches?("session.chat.send", "session.routing.send")
    end

    test "different kind denies" do
      refute Cap.matches?("session.chat.send", "workspace.chat.send")
    end
  end

  describe "matches?/2 — action wildcard / absent action" do
    test "behavior-level held cap matches all actions on that behavior" do
      assert Cap.matches?("session.chat", "session.chat.send")
      assert Cap.matches?("session.chat", "session.chat.join")
      assert Cap.matches?("session.chat", "session.chat.leave")
    end

    test "explicit action wildcard `.*` matches all actions" do
      assert Cap.matches?("session.chat.*", "session.chat.send")
      assert Cap.matches?("session.chat.*", "session.chat.join")
    end

    test "different behavior still denies" do
      refute Cap.matches?("session.chat", "session.routing.add_rule")
      refute Cap.matches?("session.chat.*", "session.routing.add_rule")
    end
  end

  describe "matches?/2 — behavior wildcard" do
    test "`session.*` matches any behavior under session kind" do
      assert Cap.matches?("session.*", "session.chat.send")
      assert Cap.matches?("session.*", "session.routing.add_rule")
      assert Cap.matches?("session.*", "session.external_mirror.bind")
    end

    test "different kind still denies" do
      refute Cap.matches?("session.*", "workspace.routing.add_rule")
    end
  end

  describe "matches?/2 — kind wildcard" do
    test "`*.chat.send` matches the action across any kind" do
      assert Cap.matches?("*.chat.send", "session.chat.send")
      assert Cap.matches?("*.chat.send", "user.chat.send")
    end

    test "different behavior or action still denies" do
      refute Cap.matches?("*.chat.send", "session.chat.join")
      refute Cap.matches?("*.chat.send", "session.routing.send")
    end
  end

  describe "matches?/2 — instance scoping" do
    test "held without instance matches any needed instance" do
      assert Cap.matches?(
               "session.chat.send",
               "session.chat.send@session://default/team/main"
             )

      assert Cap.matches?(
               "session.chat",
               "session.chat.send@session://default/team/main"
             )
    end

    test "held WITH instance matches only same instance" do
      assert Cap.matches?(
               "session.chat@session://default/team/main",
               "session.chat.send@session://default/team/main"
             )

      refute Cap.matches?(
               "session.chat@session://default/team/main",
               "session.chat.send@session://default/team/other"
             )
    end

    test "held WITH instance denies needed WITHOUT instance" do
      # held requires a specific instance; needed is unscoped → cannot
      # authorize because held only grants on that instance.
      refute Cap.matches?(
               "session.chat.send@session://default/team/main",
               "session.chat.send"
             )
    end
  end

  describe "matches?/2 — combined wildcards" do
    test "behavior-glob with instance" do
      assert Cap.matches?(
               "session.*@session://default/team/main",
               "session.chat.send@session://default/team/main"
             )

      refute Cap.matches?(
               "session.*@session://default/team/main",
               "session.chat.send@session://default/team/other"
             )
    end
  end

  describe "matches?/2 — allowlisted specials" do
    test "`cross-workspace:*` is its own special; doesn't match regular caps" do
      # It is its own membership marker, not a regular kind.behavior.action shape.
      # Existing dispatch reads it separately (cross-workspace bypass check).
      refute Cap.matches?("cross-workspace:*", "session.chat.send")
    end

    test "exact match on the special itself" do
      assert Cap.matches?("cross-workspace:*", "cross-workspace:*")
    end
  end

  describe "any_match?/2" do
    test "true when any held cap matches" do
      caps = ["user.identity.list_caps", "session.chat", "workspace.workspace.read"]
      assert Cap.any_match?(caps, "session.chat.send")
      assert Cap.any_match?(caps, "user.identity.list_caps")
    end

    test "false when no held cap matches" do
      caps = ["user.identity.list_caps", "workspace.workspace.read"]
      refute Cap.any_match?(caps, "session.chat.send")
    end

    test "false on empty list" do
      refute Cap.any_match?([], "session.chat.send")
    end

    test "`*` in held list authorizes anything" do
      caps = ["*"]
      assert Cap.any_match?(caps, "session.chat.send")
      assert Cap.any_match?(caps, "user.identity.grant_cap")
    end
  end
end
