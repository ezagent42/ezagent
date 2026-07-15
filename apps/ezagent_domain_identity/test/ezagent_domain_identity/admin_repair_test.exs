defmodule EzagentDomainIdentity.AdminRepairTest do
  use EzagentCore.DataCase, async: false

  import EzagentDomainIdentity.CapSigningTestHelpers

  alias Ezagent.Entity.{Profile, User}
  alias Ezagent.Users

  test "repair_admin_user/0 sets password+email+email_verified and preserves caps" do
    admin = User.admin_uri()
    System.put_env("EZAGENT_ADMIN_PASSWORD", "admin-secret-123")
    on_exit(fn -> System.delete_env("EZAGENT_ADMIN_PASSWORD") end)

    # Start from an admin row with no password + unverified (worst case).
    case Users.get_by_uri(admin) do
      nil ->
        admin_cap = issue!(admin, Ezagent.Capability.admin_genesis_cap(), {:genesis, admin})

        {:ok, _} =
          Users.create(admin, nil, [admin_cap],
            email_verified: false
          )

      _ ->
        :ok
    end

    assert :ok = EzagentDomainIdentity.Application.repair_admin_user()

    decoded = Users.get_by_uri(admin)
    assert decoded.email_verified == true
    assert Users.verify_password(admin, "admin-secret-123")
    assert Profile.get(admin).email == "admin@ezagent.chat"
    # genesis cap preserved
    assert decoded.caps != []
  end

  test "repair_admin_user/0 is idempotent — second call keeps the same password" do
    admin = User.admin_uri()
    System.put_env("EZAGENT_ADMIN_PASSWORD", "admin-secret-123")
    on_exit(fn -> System.delete_env("EZAGENT_ADMIN_PASSWORD") end)

    case Users.get_by_uri(admin) do
      nil -> {:ok, _} = Users.create(admin, nil, [], email_verified: false)
      _ -> :ok
    end

    assert :ok = EzagentDomainIdentity.Application.repair_admin_user()
    assert :ok = EzagentDomainIdentity.Application.repair_admin_user()
    assert Users.verify_password(admin, "admin-secret-123")
  end
end
