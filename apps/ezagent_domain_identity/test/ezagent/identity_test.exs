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

  # P3 (cap-revocation hardening): `caps_match?/2` must re-verify each
  # artifact's TARGET axis per call — `IdentityCaps.load/1`'s `verified/2` gate
  # is principal-axis, so a target regenesis AFTER the load must NOT leave a
  # stale cap "matching".
  describe "caps_match?/2 per-call target re-verify" do
    import Ezagent.Test.CapHelper,
      only: [install_test_authority!: 2, authority_signed_cap!: 3, self_license_cap!: 1]

    alias Ezagent.Cap.Authority

    test "a cap whose target was regenesis'd after IdentityCaps.load is NOT matched" do
      suffix = System.unique_integer([:positive])
      holder = Ezagent.URI.new!("entity://team-alpha/user/p3-holder-#{suffix}")
      target = Ezagent.URI.new!("entity://team-alpha/agent/p3-target-#{suffix}")

      needed = %{
        kind: :agent,
        behavior: Ezagent.ActionSet.Manage,
        action: :read_cascade,
        instance: Ezagent.URI.instance(target),
        workspace_uri: Ezagent.Capability.workspace_of(target)
      }

      authority = install_test_authority!(target, :agent)

      manage_cap =
        authority_signed_cap!(
          authority,
          holder,
          Ezagent.Capability.cap(
            :agent,
            Ezagent.ActionSet.Manage,
            :read_cascade,
            Ezagent.URI.instance(target),
            Ezagent.Capability.workspace_of(target)
          )
        )

      {:ok, _user} =
        Ezagent.Users.create_read_only(holder, [self_license_cap!(holder), manage_cap])

      loaded = Ezagent.IdentityCaps.load(holder)
      assert Enum.any?(loaded, &(&1 == manage_cap)), "precondition: the store load yields the cap"

      # Current-generation target: the loaded cap MATCHES (re-verify passes).
      assert Ezagent.Identity.caps_match?(loaded, needed)

      # Target regenesis AFTER the load: the stale (old-generation) cap must
      # NOT match anymore — the load-time principal-axis verification cannot
      # see the target's generation bump.
      {:ok, _generation_two} = Authority.regenesis(target, :agent)

      refute Ezagent.Identity.caps_match?(loaded, needed),
             "a cap whose target was regenesis'd after IdentityCaps.load MUST NOT match"
    end

    test "fail-closed: an unsigned shape-matching cap is NOT matched" do
      suffix = System.unique_integer([:positive])
      target = Ezagent.URI.new!("entity://team-alpha/agent/p3-unsigned-#{suffix}")

      needed = %{
        kind: :agent,
        behavior: Ezagent.ActionSet.Manage,
        action: :read_cascade,
        instance: Ezagent.URI.instance(target),
        workspace_uri: Ezagent.Capability.workspace_of(target)
      }

      unsigned =
        Ezagent.Capability.cap(
          :agent,
          Ezagent.ActionSet.Manage,
          :read_cascade,
          Ezagent.URI.instance(target),
          Ezagent.Capability.workspace_of(target)
        )

      refute Ezagent.Identity.caps_match?([unsigned], needed)
    end
  end
end
