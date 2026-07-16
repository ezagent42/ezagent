defmodule Ezagent.UsersTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Users

  describe "create/3" do
    # PR-甲-2 (Allen 2026-06-19, #154): `Users.create` still prepends
    # `Ezagent.Entity.User.default_caps()`, but that is now `[]` (the broad
    # session baseline is removed — participation is granted per-session at
    # join, owner-rooted). So an empty-caller-caps create yields a user with
    # NO standing caps; a custom-caps create round-trips exactly the supplied
    # caps with nothing added.

    test "empty caller caps → user starts with NO standing caps (default_caps is [])" do
      uri = "entity://team-alpha/user/test-#{System.unique_integer([:positive])}"

      {:ok, decoded} = Users.create(uri, "secret", [])

      assert URI.to_string(decoded.uri) == uri
      assert is_binary(decoded.password_hash)
      assert decoded.password_hash != "secret"

      default = Ezagent.Entity.User.default_caps(URI.new!("workspace://team-alpha"))
      assert default == []
      assert length(decoded.caps) == length(default)

      refute Enum.any?(decoded.caps, fn c ->
               c.kind == :session and c.behavior == :any
             end),
             "PR-甲-2: no broad session baseline is installed at create"
    end

    test "nil password leaves password_hash nil" do
      uri = "entity://team-alpha/user/nopw-#{System.unique_integer([:positive])}"

      {:ok, decoded} = Users.create(uri, nil, [])
      assert decoded.password_hash == nil
    end

    test "caller caps round-trip through JSON (no session baseline added — #154 甲-2)" do
      uri = "entity://team-alpha/user/caps-#{System.unique_integer([:positive])}"

      cap = %Ezagent.Capability{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        instance: :any,
        # Phase 9 PR-3 (SPEC v3 §4): caps are now workspace-scoped.
        workspace_uri: URI.new!("workspace://team-alpha"),
        granted_by: Ezagent.URI.new!("entity://system/user/admin"),
        granted_at: ~U[2026-05-16 00:00:00.000000Z]
      }

      {:ok, decoded} = Users.create(uri, "x", [cap])

      assert Enum.any?(decoded.caps, fn c ->
               c.kind == :workspace and c.behavior == Ezagent.ActionSet.Workspace
             end)

      # PR-甲-2: default_caps is [], so the ONLY cap is the caller-supplied one
      # — no broad session baseline is prepended.
      refute Enum.any?(decoded.caps, fn c ->
               c.kind == :session and c.behavior == :any
             end),
             "no session baseline should be added to the caller's caps"

      assert length(decoded.caps) == 1, "exactly the one caller-supplied cap"
    end

    test "duplicate uri returns error" do
      uri = "entity://team-alpha/user/dup-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "x", [])
      assert {:error, _changeset} = Users.create(uri, "y", [])
    end
  end

  describe "verify_password/2" do
    test "true for correct password" do
      uri = "entity://team-alpha/user/verify-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "right-pw", [])

      assert Users.verify_password(uri, "right-pw")
    end

    test "false for wrong password" do
      uri = "entity://team-alpha/user/wrong-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "right-pw", [])

      refute Users.verify_password(uri, "WRONG")
    end

    test "false for nonexistent user (no timing leak)" do
      refute Users.verify_password("entity://team-alpha/user/does-not-exist", "anything")
    end

    test "false for user with NULL password_hash (must set_password first)" do
      uri = "entity://team-alpha/user/nopw-vp-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, nil, [])

      refute Users.verify_password(uri, "anything")
    end
  end

  describe "delete/1" do
    test "a self-target call is rejected before the provisioning row is deleted" do
      uri = Ezagent.URI.user("team-alpha", "self-delete-#{System.unique_integer([:positive])}")
      assert {:ok, _user} = Users.create_read_only(uri, [])
      assert :ok = Ezagent.KindRegistry.put_new(uri)

      assert {:error, :cannot_self_destroy} = Users.delete(uri)
      assert %{uri: ^uri} = Users.get_by_uri(uri)
    end
  end

  describe "set_password/2" do
    test "updates an existing user's hash" do
      uri = "entity://team-alpha/user/setpw-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "old", [])

      assert {:ok, _} = Users.set_password(uri, "new")
      refute Users.verify_password(uri, "old")
      assert Users.verify_password(uri, "new")
    end

    test "set_password on NULL-hash row enables login" do
      uri = "entity://team-alpha/user/enable-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, nil, [])
      refute Users.verify_password(uri, "anything")

      {:ok, _} = Users.set_password(uri, "now-set")
      assert Users.verify_password(uri, "now-set")
    end

    test "returns :not_found for unknown uri" do
      assert {:error, :not_found} =
               Users.set_password(
                 "entity://team-alpha/user/never-existed-#{System.unique_integer()}",
                 "x"
               )
    end
  end

  describe "disable/enable user" do
    test "disable marks the user and blocks password verification; enable restores it" do
      uri = "entity://team-alpha/user/disabled-#{System.unique_integer([:positive])}"
      admin = "entity://system/user/admin"

      {:ok, _} = Users.create(uri, "secret", [])
      assert Users.verify_password(uri, "secret")

      assert {:ok, disabled} = Users.disable(uri, admin, "offboarded")
      assert disabled.disabled_at
      assert disabled.disabled_by == admin
      assert disabled.disabled_reason == "offboarded"
      assert Users.disabled?(uri)
      refute Users.verify_password(uri, "secret")

      assert {:ok, enabled} = Users.enable(uri)
      refute enabled.disabled_at
      refute enabled.disabled_by
      refute enabled.disabled_reason
      refute Users.disabled?(uri)
      assert Users.verify_password(uri, "secret")
    end

    test "disable is idempotent and returns :not_found for unknown users" do
      uri = "entity://team-alpha/user/disable-idem-#{System.unique_integer([:positive])}"
      admin = "entity://system/user/admin"

      {:ok, _} = Users.create(uri, "secret", [])

      assert {:ok, first} = Users.disable(uri, admin, "first")
      assert {:ok, second} = Users.disable(uri, admin, "second")
      assert first.disabled_at == second.disabled_at
      assert second.disabled_reason == "first"

      assert {:error, :not_found} =
               Users.disable(
                 "entity://team-alpha/user/no-such-#{System.unique_integer([:positive])}",
                 admin,
                 nil
               )

      assert {:error, :not_found} =
               Users.enable(
                 "entity://team-alpha/user/no-such-#{System.unique_integer([:positive])}"
               )
    end
  end

  describe "tombstone/3 (operator offboarding hard-delete, task #180)" do
    # Change 2 (task #180): delete requires the target be soft-disabled first.
    test "refuses a NOT-yet-disabled user with :must_disable_first, leaving it fully intact" do
      uri = "entity://team-alpha/user/tomb-live-#{System.unique_integer([:positive])}"
      admin = "entity://system/user/admin"

      cap = %Ezagent.Capability{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        instance: :any,
        workspace_uri: URI.new!("workspace://team-alpha"),
        granted_by: Ezagent.URI.new!("entity://system/user/admin"),
        granted_at: ~U[2026-05-16 00:00:00.000000Z]
      }

      {:ok, _} = Users.create(uri, "secret", [cap])

      # Fail-loud BEFORE any teardown: caps intact, login works, not deleted.
      assert {:error, :must_disable_first} = Users.tombstone(uri, admin, "oops")
      assert Users.get_by_uri(uri).caps != []
      assert Users.verify_password(uri, "secret")
      refute Users.deleted?(uri)

      # After disabling, delete succeeds.
      {:ok, _} = Users.disable(uri, admin, "offboarding")
      assert {:ok, deleted} = Users.tombstone(uri, admin, "confirmed")
      assert deleted.deleted_at
      assert deleted.caps == []
    end

    test "revokes durable caps so no spawn/hydration path restores authority" do
      uri = "entity://team-alpha/user/tomb-caps-#{System.unique_integer([:positive])}"
      admin = "entity://system/user/admin"

      cap = %Ezagent.Capability{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        instance: :any,
        workspace_uri: URI.new!("workspace://team-alpha"),
        granted_by: Ezagent.URI.new!("entity://system/user/admin"),
        granted_at: ~U[2026-05-16 00:00:00.000000Z]
      }

      {:ok, created} = Users.create(uri, "secret", [cap])
      assert length(created.caps) == 1
      {:ok, _} = Users.disable(uri, admin, "offboarding")

      assert {:ok, deleted} = Users.tombstone(uri, admin, "offboarded")
      # Durable authority stripped — caps_json emptied. Both the spawn
      # hydration source and the durable fallback read this, so an
      # offboarded user has NO caps regardless of which spawn fn wins.
      assert deleted.caps == []
      assert Users.get_by_uri(uri).caps == []
      assert Ezagent.EntityCaps.load_persisted(uri) == []
    end

    test "tombstones the row (preserved), blocks login, and does NOT reclaim the URI" do
      uri = "entity://team-alpha/user/tomb-#{System.unique_integer([:positive])}"
      admin = "entity://system/user/admin"

      {:ok, _} = Users.create(uri, "secret", [])
      assert Users.verify_password(uri, "secret")
      refute Users.deleted?(uri)
      {:ok, _} = Users.disable(uri, admin, "offboarding")

      assert {:ok, deleted} = Users.tombstone(uri, admin, "offboarded")
      assert deleted.deleted_at
      assert deleted.deleted_by == admin
      assert deleted.deleted_reason == "offboarded"
      # Login gate fails closed (tombstone also sets the disabled marker).
      assert deleted.disabled_at
      refute Users.verify_password(uri, "secret")
      assert Users.deleted?(uri)

      # DESTRUCTIVE but AUDIT-PRESERVING: the row is RETAINED (not purged),
      # so the URI stays occupied and CANNOT be silently re-minted.
      assert Users.get_by_uri(uri)
      assert {:error, constraint} = Users.create(uri, "new-pass", [])
      # A unique-constraint failure on the occupied URI — never a fresh row.
      assert match?(%Ecto.Changeset{}, constraint) or is_atom(constraint) or is_tuple(constraint)
      refute Users.verify_password(uri, "new-pass")
    end

    test "is idempotent and returns :not_found for unknown users" do
      uri = "entity://team-alpha/user/tomb-idem-#{System.unique_integer([:positive])}"
      admin = "entity://system/user/admin"

      {:ok, _} = Users.create(uri, "secret", [])
      {:ok, _} = Users.disable(uri, admin, "offboarding")

      assert {:ok, first} = Users.tombstone(uri, admin, "first")
      assert {:ok, second} = Users.tombstone(uri, admin, "second")
      assert first.deleted_at == second.deleted_at
      assert second.deleted_reason == "first"

      assert {:error, :not_found} =
               Users.tombstone(
                 "entity://team-alpha/user/no-such-#{System.unique_integer([:positive])}",
                 admin,
                 nil
               )
    end

    test "disabled?/1 stays true for a tombstoned user even if disabled_at is cleared (enable/delete race)" do
      uri = "entity://team-alpha/user/tomb-race-#{System.unique_integer([:positive])}"
      admin = "entity://system/user/admin"

      {:ok, _} = Users.create(uri, "secret", [])
      {:ok, _} = Users.disable(uri, admin, "off")
      {:ok, _} = Users.tombstone(uri, admin, "gone")
      assert Users.disabled?(uri)

      # Simulate a concurrent enable that cleared disabled_at AFTER the tombstone
      # set deleted_at (the TOCTOU window). `disabled?/1` must STILL fail closed
      # on deleted_at, so the eviction guard + PAT auth never re-admit the user.
      row = EzagentCore.Repo.get_by(Users, uri: uri)
      row |> Ecto.Changeset.change(%{disabled_at: nil}) |> EzagentCore.Repo.update!()

      assert Users.deleted?(uri)

      assert Users.disabled?(uri),
             "a deleted user must read as disabled even with disabled_at nil"

      refute Users.verify_password(uri, "secret")
    end

    test "enable/1 refuses a tombstoned user (delete is terminal — no misleading success)" do
      uri = "entity://team-alpha/user/tomb-enable-#{System.unique_integer([:positive])}"
      admin = "entity://system/user/admin"

      {:ok, _} = Users.create(uri, "secret", [])
      {:ok, _} = Users.disable(uri, admin, "offboarding")
      {:ok, _} = Users.tombstone(uri, admin, nil)

      assert {:error, :user_deleted} = Users.enable(uri)
      # Still tombstoned + login still blocked.
      assert Users.deleted?(uri)
      refute Users.verify_password(uri, "secret")
    end

    test "preserves a pre-existing disable timestamp/actor when deleting an already-disabled user" do
      uri = "entity://team-alpha/user/tomb-disabled-#{System.unique_integer([:positive])}"
      admin = "entity://system/user/admin"
      first_actor = "entity://team-alpha/user/manager"

      {:ok, _} = Users.create(uri, "secret", [])
      {:ok, disabled} = Users.disable(uri, first_actor, "suspended")

      assert {:ok, deleted} = Users.tombstone(uri, admin, "final offboard")
      # The delete actor is recorded on the deleted_* fields...
      assert deleted.deleted_by == admin
      # ...but the earlier disable attribution is NOT overwritten.
      assert deleted.disabled_at == disabled.disabled_at
      assert deleted.disabled_by == first_actor
    end
  end

  describe "list_all/0 + get_by_uri/1" do
    test "lists every row + lookup roundtrip" do
      uri = "entity://team-alpha/user/list-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "x", [])

      uris = Users.list_all() |> Enum.map(fn d -> URI.to_string(d.uri) end)
      assert uri in uris

      assert %{uri: %URI{}} = Users.get_by_uri(uri)
    end

    test "get_by_uri returns nil for unknown" do
      assert nil ==
               Users.get_by_uri(
                 "entity://team-alpha/user/no-such-#{System.unique_integer([:positive])}"
               )
    end
  end

  describe "email_verified (task #87 login)" do
    test "create/4 defaults email_verified to true; opt false overrides" do
      n = System.unique_integer([:positive])
      {:ok, u1} = Users.create(Ezagent.URI.user("team-alpha", "ev_a#{n}"), "pw", [])
      assert u1.email_verified == true

      {:ok, u2} =
        Users.create(Ezagent.URI.user("team-alpha", "ev_b#{n}"), "pw", [], email_verified: false)

      assert u2.email_verified == false
      assert Users.get_by_uri(u2.uri).email_verified == false
    end

    test "create_read_only stays email_verified false (anon never logs in)" do
      uri = Ezagent.URI.user("team-alpha", "ev_anon#{System.unique_integer([:positive])}")
      {:ok, u} = Users.create_read_only(uri, [])
      assert u.email_verified == false
    end

    test "mark_email_verified/1 flips an unverified user; not_found otherwise" do
      uri = Ezagent.URI.user("team-alpha", "ev_c#{System.unique_integer([:positive])}")
      {:ok, _} = Users.create(uri, "pw", [], email_verified: false)
      assert {:ok, u} = Users.mark_email_verified(uri)
      assert u.email_verified == true
      assert Users.get_by_uri(uri).email_verified == true

      assert {:error, :not_found} =
               Users.mark_email_verified(
                 Ezagent.URI.user("team-alpha", "ghost#{System.unique_integer([:positive])}")
               )
    end
  end
end
