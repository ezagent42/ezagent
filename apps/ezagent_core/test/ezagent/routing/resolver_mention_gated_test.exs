defmodule Ezagent.Routing.ResolverMentionGatedTest do
  @moduledoc """
  Mention-gated routing — `Ezagent.Routing.Resolver` tokens
  `$session_users` + `$mentions` and the shared trust boundary
  `valid_member?/2`.

  Implements `docs/superpowers/specs/2026-05-22-mention-gated-routing.md`
  §6.4 (the trust boundary — a test per drop case, for BOTH tokens).

  Each test owns a unique routing table and points the Resolver at it
  via `Application.put_env(:ezagent_core, :routing_tables, ...)`.
  """

  use ExUnit.Case, async: false
  alias Ezagent.{Message, RoutingRegistry}
  alias Ezagent.Routing.{Matcher, Resolver}

  setup do
    test_table = :"resolver_mg_test_#{System.unique_integer([:positive])}"
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

  # session://default/system/main — workspace is `default`.
  @session URI.new!("session://default/team-alpha/main")
  @sender "entity://user/team-alpha/admin"

  defp msg(text, mentions \\ []) do
    Message.new(URI.new!(@sender), %{text: text, attachments: []},
      mentions: Enum.map(mentions, &URI.new!/1)
    )
  end

  defp strs(uris), do: uris |> Enum.map(&URI.to_string/1) |> Enum.sort()

  describe "token vocabulary" do
    test "magic_tokens/0 + magic_token?/1" do
      assert Resolver.magic_tokens() == [
               "$session_members",
               "$session_users",
               "$mentions"
             ]

      assert Resolver.magic_token?("$session_members")
      assert Resolver.magic_token?("$session_users")
      assert Resolver.magic_token?("$mentions")
      refute Resolver.magic_token?("entity://user/team-alpha/admin")
      refute Resolver.magic_token?(:anything)
    end

    test "session_users_token/0 + mentions_token/0" do
      assert Resolver.session_users_token() == "$session_users"
      assert Resolver.mentions_token() == "$mentions"
    end
  end

  describe "$session_users expansion" do
    test "expands to validly-member User URIs, excludes Agents + sender", %{table: t} do
      :ok = RoutingRegistry.put(t, Matcher.always(), ["$session_users"])

      members = [
        URI.new!(@sender),
        URI.new!("entity://user/team-alpha/bob"),
        URI.new!("entity://agent/team-alpha/cc_echo")
      ]

      result = Resolver.resolve(msg("hi"), @session, members)
      # admin is sender (excluded), cc_echo is an Agent (not a User);
      # only bob survives.
      assert strs(result) == ["entity://user/team-alpha/bob"]
    end
  end

  describe "$mentions expansion" do
    test "expands to validly-mentioned members only", %{table: t} do
      :ok = RoutingRegistry.put(t, Matcher.always(), ["$mentions"])

      agent = "entity://agent/team-alpha/cc_echo"

      members = [
        URI.new!(@sender),
        URI.new!(agent)
      ]

      result = Resolver.resolve(msg("hey", [agent]), @session, members)
      assert strs(result) == [agent]
    end

    test "no mention → empty (mention is the gate)", %{table: t} do
      :ok = RoutingRegistry.put(t, Matcher.always(), ["$mentions"])

      members = [URI.new!(@sender), URI.new!("entity://agent/team-alpha/cc_echo")]
      assert Resolver.resolve(msg("hey", []), @session, members) == []
    end
  end

  # SPEC §6.4 — the trust boundary, a dedicated test per drop case,
  # for BOTH tokens. valid_member?/2 must drop every one.
  describe "trust boundary — $mentions drops invalid candidates" do
    setup %{table: t} do
      :ok = RoutingRegistry.put(t, Matcher.always(), ["$mentions"])
      :ok
    end

    test "(a) non-member is dropped" do
      # cc_echo is mentioned but is NOT in the members list.
      members = [URI.new!(@sender)]

      result =
        Resolver.resolve(msg("hi", ["entity://agent/team-alpha/cc_echo"]), @session, members)

      assert result == []
    end

    test "(b) cross-workspace URI is dropped" do
      # The candidate is a member by URI string but lives in a
      # DIFFERENT workspace than the session (`default`).
      cross = "entity://agent/other-ws/cc_echo"
      members = [URI.new!(@sender), URI.new!(cross)]
      result = Resolver.resolve(msg("hi", [cross]), @session, members)
      assert result == []
    end

    test "(c) a different session's URI is dropped" do
      # A session:// URI for a different session — not a member of
      # THIS session, and (if it were) cross-session.
      other = "session://default/team-alpha/other"
      members = [URI.new!(@sender), URI.new!(other)]
      result = Resolver.resolve(msg("hi", [other]), @session, members)
      assert result == []
    end

    test "(d) a malformed candidate is dropped" do
      # A hand-built %URI{} with a non-canonical / non-entity scheme.
      bad = %URI{scheme: "ftp", host: "nope", path: "/x"}
      m = Message.new(URI.new!(@sender), %{text: "hi", attachments: []}, mentions: [bad])
      members = [URI.new!(@sender)]
      assert Resolver.resolve(m, @session, members) == []
    end

    # codex HIGH-1: the real mention sources build `%URI{}` via
    # `URI.new/URI.new!` — NOT `Ezagent.URI.new!`. A hand-built
    # struct carrying an extra path segment violates the SPEC-v3
    # 3-segment / reserved-sub-resource rule but, before the fix,
    # passed through `valid_member?/2` unchecked because only the
    # binary path ran the strict parser. It must be dropped even
    # when it is present in `members`.
    test "(e) a %URI{} agent member with an extra path segment is dropped" do
      # entity://agent/team-alpha/cc_x/extra — 4-segment, reserved
      # sub-resource position. `URI.new!/1` builds it happily; the
      # strict `Ezagent.URI.new!/1` rejects it.
      bad = %URI{scheme: "entity", host: "agent", path: "/team-alpha/cc_x/extra"}
      m = Message.new(URI.new!(@sender), %{text: "hi", attachments: []}, mentions: [bad])
      # Present in members — the membership check alone would have
      # accepted it; the strict shape check is what drops it.
      members = [URI.new!(@sender), bad]
      assert Resolver.resolve(m, @session, members) == []
    end

    test "(f) a %URI{} user member with an extra path segment is dropped" do
      bad = %URI{scheme: "entity", host: "user", path: "/team-alpha/bob/extra"}
      m = Message.new(URI.new!(@sender), %{text: "hi", attachments: []}, mentions: [bad])
      members = [URI.new!(@sender), bad]
      assert Resolver.resolve(m, @session, members) == []
    end
  end

  describe "trust boundary — $session_users drops invalid candidates" do
    setup %{table: t} do
      :ok = RoutingRegistry.put(t, Matcher.always(), ["$session_users"])
      :ok
    end

    test "(b) a cross-workspace User in slice.members receives NOTHING" do
      # rev-3 HIGH-a: a cross-workspace User placed in slice.members
      # programmatically (chat.join / template instantiation) must NOT
      # leak. valid_member?/2 is the workspace boundary.
      cross_user = "entity://user/other-ws/spy"
      members = [URI.new!(@sender), URI.new!(cross_user)]
      result = Resolver.resolve(msg("hi"), @session, members)
      # @sender is excluded as sender; cross-ws user is dropped by the
      # workspace check → zero recipients.
      assert result == []
    end

    test "in-workspace User member IS delivered (positive control)" do
      members = [URI.new!(@sender), URI.new!("entity://user/team-alpha/bob")]
      result = Resolver.resolve(msg("hi"), @session, members)
      assert strs(result) == ["entity://user/team-alpha/bob"]
    end

    # codex HIGH-1: an extra-segment %URI{} User struct sitting in
    # `slice.members` (where `$session_users` reads from directly,
    # not from `message.mentions`) must also be dropped — the strict
    # shape validation applies to BOTH tokens.
    test "(g) a %URI{} user member with an extra path segment receives NOTHING" do
      bad = %URI{scheme: "entity", host: "user", path: "/team-alpha/bob/extra"}
      members = [URI.new!(@sender), bad]
      result = Resolver.resolve(msg("hi"), @session, members)
      assert result == []
    end
  end

  describe "valid_member?/2 directly" do
    test "true for an in-workspace, registered member" do
      bob = URI.new!("entity://user/team-alpha/bob")
      assert Resolver.valid_member?(bob, @session, [bob])
    end

    test "false for a non-member" do
      refute Resolver.valid_member?(
               URI.new!("entity://user/team-alpha/bob"),
               @session,
               []
             )
    end

    test "false for a cross-workspace member" do
      cross = URI.new!("entity://user/other-ws/bob")
      refute Resolver.valid_member?(cross, @session, [cross])
    end

    test "false for a cross-session member" do
      other_session = URI.new!("session://default/team-alpha/other")
      refute Resolver.valid_member?(other_session, @session, [other_session])
    end

    test "false (never raises) for a malformed candidate" do
      refute Resolver.valid_member?("not a uri at all", @session, [])
      refute Resolver.valid_member?(%URI{scheme: "ftp"}, @session, [])
    end

    # codex HIGH-1: a hand-built %URI{} struct with an extra path
    # segment must fail identically to its binary equivalent — the
    # strict `Ezagent.URI.new!/1` validation applies to BOTH input
    # forms, not just binaries.
    test "false for a %URI{} struct with an extra path segment (binary + struct parity)" do
      bad_str = "entity://agent/team-alpha/cc_x/extra"
      bad_struct = %URI{scheme: "entity", host: "agent", path: "/team-alpha/cc_x/extra"}

      # Both forms present in members — only the strict shape check
      # rejects them.
      refute Resolver.valid_member?(bad_str, @session, [bad_struct])
      refute Resolver.valid_member?(bad_struct, @session, [bad_struct])

      # Parity: the binary path already dropped it; the struct path
      # now drops it the same way.
      assert Resolver.valid_member?(bad_str, @session, [bad_struct]) ==
               Resolver.valid_member?(bad_struct, @session, [bad_struct])
    end

    test "a peer session:// URI is cross-session → invalid (SPEC §6.4 c)" do
      # Even in the same workspace and even if it is in `members`, a
      # session:// URL naming a DIFFERENT session is cross-session.
      peer = URI.new!("session://default/team-alpha/peer")
      refute Resolver.valid_member?(peer, @session, [peer])
    end

    test "the current session's own URI is not cross-session" do
      # @session itself is not cross-session (it is the current one).
      # It must also be a member to be valid_member?-true.
      assert Resolver.valid_member?(@session, @session, [@session])
    end
  end
end
