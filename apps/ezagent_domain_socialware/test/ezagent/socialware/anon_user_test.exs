defmodule Ezagent.Socialware.AnonUserTest do
  @moduledoc """
  Issue #51 — the anonymous external-user minting primitive.

  `AnonUser.mint/1` mints a flavor of the User Kind —
  `entity://<viewed-workspace>/user/anon-<random>` — that is **read-only by
  construction**: its `users` row has an EMPTY caps_json (NO
  `User.default_caps/1`), so `User.initial_caps_for_spawn/1` hydrates it with no
  session cap. The read-only-ness IS the absence of a session write cap — there is
  no `is_anon?` flag, no guest allow-list (membership-only principle, spec §2).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.Socialware.AnonUser
  alias Ezagent.Users

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :default,
      "anon-mint-#{System.unique_integer([:positive])}"
    )
  end

  describe "mint/1 — a read-only anon-User in the viewed session's workspace" do
    test "mints a canonical bare-principal user URI with the anon- prefix" do
      assert {:ok, %URI{} = anon} = AnonUser.mint(session_uri())

      assert Ezagent.URI.bare_principal?(anon)
      assert Ezagent.URI.type?(anon, :user)
      assert {:ok, name} = Ezagent.URI.name(anon)
      assert String.starts_with?(name, "anon-")
    end

    test "the anon-User's workspace segment is the VIEWED session's workspace" do
      session = session_uri()
      assert {:ok, anon} = AnonUser.mint(session)

      assert Ezagent.URI.workspace_name(anon) == Ezagent.URI.workspace_name(session)
    end

    test "each mint is unique (128-bit random tail — no collision)" do
      session = session_uri()
      assert {:ok, a} = AnonUser.mint(session)
      assert {:ok, b} = AnonUser.mint(session)
      assert a != b
    end

    test "READ-ONLY BY CONSTRUCTION: the backing row has an EMPTY cap set" do
      assert {:ok, anon} = AnonUser.mint(session_uri())

      # The provisioning row exists...
      assert %{caps: caps} = Users.get_by_uri(anon)
      # ...but with NO caps (no default_caps prepended) — so the demand-spawned
      # User Kind would hold only the structural self-Identity cap, never a
      # session write cap. A chat.send would be denied at CapBAC step 5.5.
      assert caps == []
    end

    test "READ-ONLY BY CONSTRUCTION: initial_caps_for_spawn yields no session cap" do
      assert {:ok, anon} = AnonUser.mint(session_uri())

      spawn_caps = User.initial_caps_for_spawn(anon)

      refute Enum.any?(MapSet.to_list(spawn_caps), fn cap ->
               match?(%Ezagent.Capability{kind: :session}, cap)
             end)
    end

    test "the anon-User is NOT a login principal (no password_hash → login refused)" do
      assert {:ok, anon} = AnonUser.mint(session_uri())
      refute Users.verify_password(anon, "anything")
    end

    test "rejects a non-session URI" do
      not_a_session = Ezagent.URI.entity(:team_alpha, :user, "real-person")
      assert {:error, _} = AnonUser.mint(not_a_session)
    end
  end

  describe "anon_uri?/1 — the GC + filter predicate" do
    test "true for a minted anon-User" do
      assert {:ok, anon} = AnonUser.mint(session_uri())
      assert AnonUser.anon_uri?(anon)
    end

    test "false for an ordinary user URI" do
      refute AnonUser.anon_uri?(Ezagent.URI.entity(:team_alpha, :user, "alice"))
    end

    test "false for an agent / session / nil / non-URI" do
      refute AnonUser.anon_uri?(Ezagent.URI.entity(:team_alpha, :agent, "anon-bot"))
      refute AnonUser.anon_uri?(Ezagent.URI.session(:team_alpha, :default, "anon-x"))
      refute AnonUser.anon_uri?(nil)
      refute AnonUser.anon_uri?("entity://team-alpha/user/anon-x")
    end
  end
end
