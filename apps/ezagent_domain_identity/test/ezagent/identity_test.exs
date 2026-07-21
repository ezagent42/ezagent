defmodule Ezagent.IdentityTest do
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_fixture_cap!: 5]

  describe "list_caps_for/1" do
    test "returns empty MapSet for not-yet-spawned user" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/user/never-spawned-#{System.unique_integer([:positive])}"
        )

      caps = Ezagent.Identity.list_caps_for(uri)
      assert %MapSet{} = caps
      assert MapSet.size(caps) == 0
    end

    test "returns only born-signed caps for the live admin Kind" do
      # PR-M (2026-05-20): admin User Kind is no longer a static
      # supervisor child — it spawns lazily on first reference. The
      # production password-login path (`Ezagent.Entity.authenticate_password/2`) calls
      # `ensure_spawned/1` which hydrates caps from the `users` DB row
      # (populated by `EzagentDomainIdentity.Application.ensure_admin_user/0`
      # at boot). For this direct-read test, spawn explicitly via
      # SpawnRegistry; the boot-time DB hydration is what makes the
      # slice reflect admin_caps.
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(Ezagent.Entity.User.admin_uri())

      caps = Ezagent.Identity.list_caps_for(Ezagent.Entity.User.admin_uri())

      assert MapSet.size(caps) >= 1

      assert Enum.all?(caps, fn cap ->
               is_binary(cap.signature) and is_binary(cap.key_id) and
                 cap.grantee_uri == Ezagent.Entity.User.admin_uri()
             end)
    end
  end

  describe "verified durable cap loading" do
    test "I5 read_held_caps filters an invalid caps_json artifact" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/user/verify-loader-#{System.unique_integer([:positive])}"
        )

      valid =
        signed_fixture_cap!(
          Ezagent.URI.new!("session://team-alpha/default/verify-loader"),
          :session,
          Ezagent.ActionSet.Session,
          :send,
          uri
        )

      invalid = %{valid | grantee_uri: Ezagent.URI.new!("entity://team-alpha/user/other")}

      assert {:ok, _user} = Ezagent.Users.create(uri, nil, [valid, invalid])
      assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)

      held = Ezagent.Identity.read_held_caps(uri)

      assert MapSet.member?(held, valid)
      refute MapSet.member?(held, invalid)
      assert Enum.any?(held, &(Ezagent.Capability.action_of(&1) == :self_license))
    end
  end

  describe "admin?/1 (Phase 8c PR-F)" do
    test "returns true for the seeded admin URI (struct form)" do
      assert Ezagent.Identity.admin?(Ezagent.Entity.User.admin_uri())
    end

    test "returns true for the seeded admin URI (string form)" do
      assert Ezagent.Identity.admin?("entity://system/user/admin")
    end

    test "returns false for a non-admin user URI" do
      refute Ezagent.Identity.admin?("entity://team-alpha/user/alice")
      refute Ezagent.Identity.admin?(Ezagent.URI.new!("entity://team-alpha/user/bob"))
    end

    test "returns false for an agent URI" do
      refute Ezagent.Identity.admin?("entity://team-alpha/agent/claude-1")
    end

    test "returns false for nil" do
      refute Ezagent.Identity.admin?(nil)
    end

    test "returns false for a malformed URI string" do
      refute Ezagent.Identity.admin?("not a uri")
      refute Ezagent.Identity.admin?("")
    end

    test "returns false for any other input type" do
      refute Ezagent.Identity.admin?(:admin)
      refute Ezagent.Identity.admin?(42)
    end
  end
end
