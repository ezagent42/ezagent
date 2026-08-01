defmodule Ezagent.Identity.AdminUnkillableTest do
  @moduledoc """
  #1627 B1-hybrid — the genesis admin is structurally un-killable via the
  identity-plane kill paths (`Users.delete`, `RevocationFence.enroll`), while a
  REGULAR principal's delete/fence still works.

  (The sanctioned `AdminKeyRotation` rotate + re-mint is proven end-to-end in the
  isolated `apps/ezagent_domain_session/test/integration/admin_key_rotation_test.exs`
  — it mutates the VM-global admin singleton, so it runs ALONE in the
  `session_admin_rotation` CI shard rather than corrupting this suite.)
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.Identity.Offboarding.RevocationFence

  defp admin, do: User.admin_uri()

  defp unique_user(suffix),
    do: Ezagent.URI.user("team-alpha", "unkill-#{suffix}-#{System.unique_integer([:positive])}")

  describe "admin is un-deletable; a regular user still deletes" do
    test "Users.delete/1 REJECTS the genesis admin" do
      assert {:error, :cannot_delete_admin} = Ezagent.Users.delete(admin())
    end

    test "Users.delete/1 still deletes a REGULAR user" do
      user = unique_user("del")
      assert {:ok, _} = Ezagent.Users.create(user, nil, [])
      assert Ezagent.Users.get_by_uri(user)

      assert :ok = Ezagent.Users.delete(user)
      refute Ezagent.Users.get_by_uri(user)
    end
  end

  describe "admin cannot be offboarding-fenced; a regular principal can" do
    test "RevocationFence.enroll/1 REJECTS a list containing the admin" do
      assert {:error, :root_authority_immutable} = RevocationFence.enroll([admin()])
      refute RevocationFence.fenced?(admin())
    end

    test "RevocationFence.enroll/1 still fences a REGULAR principal" do
      user = unique_user("fence")
      assert :ok = RevocationFence.enroll([user])
      assert RevocationFence.fenced?(user)
    end
  end

  describe "admin cannot be destroyed via Lifecycle.destroy (codex r3 hardening 1)" do
    alias Ezagent.Cap.Authority

    test "Lifecycle.destroy/2 REJECTS the genesis admin BEFORE any teardown; authority intact" do
      {:ok, _authority} = Authority.open(admin(), :user)
      assert {:ok, gen_before} = Authority.current_generation(admin())

      # `manage:delete` / offboarding-reaper / session-teardown all route through
      # `Ezagent.Lifecycle.destroy/2` → `do_destroy`, which retires the authority +
      # clears the ever_created marker. The root guard rejects the admin at that
      # chokepoint BEFORE any hook/terminate/retire runs.
      assert {:error, :root_authority_immutable} = Ezagent.Lifecycle.destroy(admin())

      # No teardown ran — the admin's authority row (and its generation) is intact,
      # so its next reference re-spawns cleanly (no soft kill).
      assert {:ok, ^gen_before} = Authority.current_generation(admin())
    end

    test "Lifecycle.destroy/2 does NOT root-reject a NON-admin target (destroy-of-others intact)" do
      user = unique_user("destroy")
      refute match?({:error, :root_authority_immutable}, Ezagent.Lifecycle.destroy(user))
    end
  end
end
