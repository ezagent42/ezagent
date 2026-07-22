defmodule Ezagent.Session.MembershipTest do
  @moduledoc """
  The SHARED live, fail-closed chat owner/member predicate — extracted from
  `Ezagent.ActionSet.SocialwarePublisherRead` (P3-3) so BOTH that behavior's
  read authz AND the P4 chat_feed external read call ONE predicate (no
  copy-paste drift on a security boundary).

  These cases are the EXACT branches of the P3-3 `valid_caller_uri?` +
  canonical-principal and fail-closed predicate, asserted directly against the
  `(chat_slice, caller)` form. The byte-equivalence with P3-3 is also asserted
  by `socialware_publisher_read_test.exs` continuing to pass (it now delegates
  here).

  Authorize ONLY when ALL hold (else `{:error, :unauthorized}`):
    - `caller` is a WELL-FORMED identity-principal `%URI{}` (canonical
      `entity://<ws>/<user|agent|worker>/<name>`, reconstruct-and-compare);
    - the `:chat` slice is present + readable (a map);
    - the caller holds the current tier-1 member cap over a concrete session.
  Owner and roster projection fields never authorize, and a missing session
  context fails closed.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Session.Membership

  @owner Ezagent.URI.entity(:team_alpha, :user, "owner-cm")
  @member Ezagent.URI.entity(:team_alpha, :agent, "member-cm")
  @stranger Ezagent.URI.entity(:team_alpha, :user, "stranger-cm")
  @session Ezagent.URI.session(:team_alpha, :default, "cm-1")

  defp owned_chat(owner, members \\ %{}) do
    %{owner_uri: owner, members: members, last_seen: %{}}
  end

  defp authorize(chat, caller), do: Membership.authorize(chat, caller, nil, caller)

  describe "authorize/4 — projection fields are not authority" do
    test "owner_uri == caller does not authorize without a concrete held cap" do
      assert {:error, :unauthorized} = authorize(owned_chat(@owner), @owner)
    end

    test "caller in members does not authorize without a concrete held cap" do
      chat = owned_chat(@owner, %{@member => %{online: true}})
      assert {:error, :unauthorized} = authorize(chat, @member)
    end
  end

  describe "authorize/2 — non-member denied (incl. ex-member via LIVE re-check)" do
    test "a stranger who is neither owner nor member → unauthorized" do
      chat = owned_chat(@owner, %{@member => %{online: true}})
      assert {:error, :unauthorized} = authorize(chat, @stranger)
    end

    test "stale or absent projection is denied when no cap is held" do
      joined = owned_chat(@owner, %{@member => %{online: true}})
      assert {:error, :unauthorized} = authorize(joined, @member)

      left = owned_chat(@owner, %{})
      assert {:error, :unauthorized} = authorize(left, @member)
    end
  end

  describe "authorize/2 — nil/:any/:system/owner-nil traps" do
    test "nil caller, nil owner, empty members → unauthorized (no allow-if-owner-nil)" do
      assert {:error, :unauthorized} = authorize(owned_chat(nil, %{}), nil)
    end

    test ":any caller, nil owner → unauthorized" do
      assert {:error, :unauthorized} = authorize(owned_chat(nil, %{}), :any)
    end

    test ":system caller, nil owner → unauthorized" do
      assert {:error, :unauthorized} = authorize(owned_chat(nil, %{}), :vm_internal)
    end
  end

  describe "authorize/2 — malformed / crafted caller denied" do
    test "binary caller → unauthorized" do
      assert {:error, :unauthorized} = authorize(owned_chat(@owner), "entity://x")
    end

    test "map caller → unauthorized" do
      assert {:error, :unauthorized} =
               authorize(owned_chat(@owner), %{not: "a uri"})
    end

    test "non-canonical (:authority-set) %URI{} → unauthorized even if equals owner_uri" do
      malformed = URI.parse("entity://team-alpha/user/owner-cm")
      assert malformed.authority != nil
      assert {:error, :unauthorized} = authorize(owned_chat(malformed), malformed)
    end

    test "non-entity %URI{} caller (session scheme) → unauthorized even as owner_uri" do
      assert {:error, :unauthorized} =
               authorize(owned_chat(@session), @session)
    end

    test "entity %URI{} with non-principal path → unauthorized" do
      bad = %URI{scheme: "entity", host: "team-alpha", path: "/notatype/x"}
      assert {:error, :unauthorized} = authorize(owned_chat(bad), bad)
    end

    test "entity %URI{} with a SUBRESOURCE path → unauthorized even as owner_uri" do
      sub = %URI{scheme: "entity", host: "team-alpha", path: "/user/alice/auth/login"}
      assert {:error, :unauthorized} = authorize(owned_chat(sub), sub)
    end

    test "entity %URI{} carrying a QUERY → unauthorized even as owner_uri" do
      q = %URI{scheme: "entity", host: "team-alpha", path: "/user/alice", query: "action=x"}
      assert {:error, :unauthorized} = authorize(owned_chat(q), q)
    end

    test "entity %URI{} carrying a FRAGMENT → unauthorized even as owner_uri" do
      f = %URI{scheme: "entity", host: "team-alpha", path: "/user/alice", fragment: "x"}
      assert {:error, :unauthorized} = authorize(owned_chat(f), f)
    end

    test "entity %URI{} carrying USERINFO → unauthorized as owner_uri AND as member" do
      u = %URI{scheme: "entity", host: "team-alpha", userinfo: "evil", path: "/user/alice"}
      assert {:error, :unauthorized} = authorize(owned_chat(u), u)

      chat = %{owner_uri: nil, members: %{u => %{online: true}}, last_seen: %{}}
      assert {:error, :unauthorized} = authorize(chat, u)
    end

    test "entity %URI{} carrying a PORT → unauthorized even as owner_uri" do
      p = %URI{scheme: "entity", host: "team-alpha", port: 443, path: "/user/alice"}
      assert {:error, :unauthorized} = authorize(owned_chat(p), p)
    end
  end

  describe "authorize/2 — missing / unreadable chat slice → fail closed" do
    test "owner caller but chat slice not a map → unauthorized" do
      assert {:error, :unauthorized} = authorize(:not_a_map, @owner)
    end

    test "owner caller but chat slice nil → unauthorized" do
      assert {:error, :unauthorized} = authorize(nil, @owner)
    end
  end

  describe "valid_caller_uri?/1 — exposed for the SPR delegation" do
    test "a canonical principal is valid" do
      assert Membership.valid_caller_uri?(@owner)
    end

    test "a non-canonical / crafted caller is invalid" do
      refute Membership.valid_caller_uri?(URI.parse("entity://team-alpha/user/owner-cm"))
      refute Membership.valid_caller_uri?(nil)
      refute Membership.valid_caller_uri?(:any)
      refute Membership.valid_caller_uri?(@session)
    end
  end
end
