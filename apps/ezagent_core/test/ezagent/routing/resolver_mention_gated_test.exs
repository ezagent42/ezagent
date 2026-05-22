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

  # session://default/default/main — workspace is `default`.
  @session URI.new!("session://default/default/main")
  @sender "entity://user/default/admin"

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
      refute Resolver.magic_token?("entity://user/default/admin")
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
        URI.new!("entity://user/default/bob"),
        URI.new!("entity://agent/default/cc_echo")
      ]

      result = Resolver.resolve(msg("hi"), @session, members)
      # admin is sender (excluded), cc_echo is an Agent (not a User);
      # only bob survives.
      assert strs(result) == ["entity://user/default/bob"]
    end
  end

  describe "$mentions expansion" do
    test "expands to validly-mentioned members only", %{table: t} do
      :ok = RoutingRegistry.put(t, Matcher.always(), ["$mentions"])

      agent = "entity://agent/default/cc_echo"

      members = [
        URI.new!(@sender),
        URI.new!(agent)
      ]

      result = Resolver.resolve(msg("hey", [agent]), @session, members)
      assert strs(result) == [agent]
    end

    test "no mention → empty (mention is the gate)", %{table: t} do
      :ok = RoutingRegistry.put(t, Matcher.always(), ["$mentions"])

      members = [URI.new!(@sender), URI.new!("entity://agent/default/cc_echo")]
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
      result = Resolver.resolve(msg("hi", ["entity://agent/default/cc_echo"]), @session, members)
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
      other = "session://default/default/other"
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
      members = [URI.new!(@sender), URI.new!("entity://user/default/bob")]
      result = Resolver.resolve(msg("hi"), @session, members)
      assert strs(result) == ["entity://user/default/bob"]
    end
  end

  describe "valid_member?/2 directly" do
    test "true for an in-workspace, registered member" do
      bob = URI.new!("entity://user/default/bob")
      assert Resolver.valid_member?(bob, @session, [bob])
    end

    test "false for a non-member" do
      refute Resolver.valid_member?(
               URI.new!("entity://user/default/bob"),
               @session,
               []
             )
    end

    test "false for a cross-workspace member" do
      cross = URI.new!("entity://user/other-ws/bob")
      refute Resolver.valid_member?(cross, @session, [cross])
    end

    test "false for a cross-session member" do
      other_session = URI.new!("session://default/default/other")
      refute Resolver.valid_member?(other_session, @session, [other_session])
    end

    test "false (never raises) for a malformed candidate" do
      refute Resolver.valid_member?("not a uri at all", @session, [])
      refute Resolver.valid_member?(%URI{scheme: "ftp"}, @session, [])
    end

    test "a peer session:// URI is cross-session → invalid (SPEC §6.4 c)" do
      # Even in the same workspace and even if it is in `members`, a
      # session:// URL naming a DIFFERENT session is cross-session.
      peer = URI.new!("session://default/default/peer")
      refute Resolver.valid_member?(peer, @session, [peer])
    end

    test "the current session's own URI is not cross-session" do
      # @session itself is not cross-session (it is the current one).
      # It must also be a member to be valid_member?-true.
      assert Resolver.valid_member?(@session, @session, [@session])
    end
  end
end
