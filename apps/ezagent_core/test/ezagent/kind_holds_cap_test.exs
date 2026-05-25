defmodule Ezagent.Kind.HoldsCapTest do
  use ExUnit.Case, async: true

  alias Ezagent.Kind

  describe "holds_cap?/2 (default impl) — string caps in slice" do
    test "returns true when slice has matching cap string" do
      slice = %{identity: %{caps: ["session.chat.send"]}}
      assert Kind.holds_cap?(slice, "session.chat.send")
    end

    test "returns true when held cap matches via wildcard" do
      slice = %{identity: %{caps: ["session.chat.*"]}}
      assert Kind.holds_cap?(slice, "session.chat.send")
      assert Kind.holds_cap?(slice, "session.chat.join")
    end

    test "returns true when held has `*` admin wildcard" do
      slice = %{identity: %{caps: ["*"]}}
      assert Kind.holds_cap?(slice, "session.chat.send")
      assert Kind.holds_cap?(slice, "user.identity.grant_cap")
    end

    test "returns false when no held cap matches" do
      slice = %{identity: %{caps: ["session.chat.send"]}}
      refute Kind.holds_cap?(slice, "user.identity.grant_cap")
    end

    test "returns false when slice has empty cap list" do
      slice = %{identity: %{caps: []}}
      refute Kind.holds_cap?(slice, "session.chat.send")
    end

    test "returns false when slice has no :identity sub-key" do
      refute Kind.holds_cap?(%{}, "session.chat.send")
      refute Kind.holds_cap?(%{api_keys: %{}}, "session.chat.send")
    end

    test "returns false when :identity has no :caps key" do
      slice = %{identity: %{some_other_field: 1}}
      refute Kind.holds_cap?(slice, "session.chat.send")
    end
  end

  describe "holds_cap?/2 — legacy MapSet shape (PR-CC-2a transitional)" do
    test "MapSet of strings still works" do
      slice = %{identity: %{caps: MapSet.new(["session.chat.send"])}}
      assert Kind.holds_cap?(slice, "session.chat.send")
    end

    test "MapSet with struct caps (legacy) — structs filtered out, no crash" do
      # Simulate a half-migrated slice with mixed legacy structs + new strings.
      legacy_struct = %Ezagent.Capability{
        kind: :session,
        behavior: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: URI.parse("system://bootstrap"),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      slice = %{identity: %{caps: MapSet.new([legacy_struct, "session.chat.send"])}}
      # The string cap is honored; the struct is filtered out (won't crash).
      assert Kind.holds_cap?(slice, "session.chat.send")
      refute Kind.holds_cap?(slice, "user.identity.grant_cap")
    end
  end

  describe "holds_cap?/3 — module dispatcher" do
    defmodule OverrideKind do
      @behaviour Ezagent.Kind

      def type_name, do: :override
      def behaviors, do: []
      def persistence, do: :ephemeral

      # Custom override: yes for "magic.cap", no otherwise.
      def holds_cap?(_slice, "magic.cap"), do: true
      def holds_cap?(_slice, _other), do: false
    end

    defmodule NoOverrideKind do
      @behaviour Ezagent.Kind

      def type_name, do: :no_override
      def behaviors, do: []
      def persistence, do: :ephemeral
    end

    test "exported override takes precedence" do
      assert Kind.holds_cap?(OverrideKind, %{identity: %{caps: []}}, "magic.cap")
      refute Kind.holds_cap?(OverrideKind, %{identity: %{caps: ["session.chat.send"]}}, "session.chat.send")
    end

    test "Kind without override falls through to default" do
      slice = %{identity: %{caps: ["session.chat.send"]}}
      assert Kind.holds_cap?(NoOverrideKind, slice, "session.chat.send")
      refute Kind.holds_cap?(NoOverrideKind, slice, "user.identity.grant_cap")
    end
  end
end
