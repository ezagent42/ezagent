defmodule EzagentDomainInstanceMessage.Integration.AdminKeyRotationTest do
  @moduledoc """
  #1627 B1-hybrid — the sanctioned manual admin key-rotation operator command
  (`Ezagent.Identity.AdminKeyRotation`). The admin is structurally un-killable, so
  rotation is the ONE way to advance the root's generation; it rotates the
  authority AND re-mints the self-license under the new generation atomically (one
  transaction under the authority-row lock) — no stale-generation admin window.

  This spawns + rotates + terminates the VM-GLOBAL genesis-admin singleton, so it
  runs ALONE in the isolated `session_admin_rotation` CI shard (`@moduletag
  :real_boot_seed_path`, excluded from the default suite) rather than corrupting
  sibling tests that depend on the live admin.
  """

  use EzagentCore.DataCase, async: false

  @moduletag :real_boot_seed_path

  alias Ezagent.Cap.Authority
  alias Ezagent.Capability
  alias Ezagent.Entity.User
  alias Ezagent.IdentityCaps
  alias Ezagent.Identity.AdminKeyRotation

  defp admin, do: User.admin_uri()

  defp self_licenses(caps),
    do: Enum.filter(caps, &(Capability.action_of(&1) == :self_license))

  test "rotates the admin generation and re-mints a CURRENT self-license atomically" do
    on_exit(fn ->
      _ = Ezagent.Kind.terminate!(admin())
      _ = Ezagent.LocalRuntime.ensure_started(admin())
    end)

    # Bootstrap the admin to currency (authority + live Kind), then take it
    # offline so the rotation's own terminate is a no-op and no live-state races
    # the sandbox.
    _ = Ezagent.Cap.authorization_context({:admin, admin()})
    assert {:ok, gen0} = Authority.current_generation(admin())
    _ = Ezagent.Kind.terminate!(admin())

    assert {:ok, gen1} = AdminKeyRotation.run(io: fn _ -> :ok end)
    assert gen1 == gen0 + 1

    # The re-minted self-license is durable AND current under the new generation
    # (rotate + re-mint were atomic — no stale-gen window).
    assert [license] = self_licenses(IdentityCaps.load_persisted(admin()))
    assert Authority.verify_against_current(license, admin(), admin())

    # codex r3 hardening 2 (Landmine A): the AUTHORITATIVE identity-caps store row
    # is `active` — the in-txn persist's `verify_against_current` saw the newly
    # rotated authority (same connection) and did NOT strand the license as
    # `revoked_unprovisioned` (which would `:holder_revoked`-brick a post-epoch boot
    # while every other assertion here still passed).
    assert IdentityCaps.Store.status(admin()) == :active
  end

  test "a persist failure INSIDE the rotation txn rolls the WHOLE rotation back (atomicity)" do
    on_exit(fn ->
      Application.delete_env(:ezagent_domain_identity, :admin_rotation_forced_persist_error)
      _ = Ezagent.Kind.terminate!(admin())
      _ = Ezagent.LocalRuntime.ensure_started(admin())
    end)

    # Bootstrap to currency and capture the pre-rotation generation + a
    # currently-valid self-license, then take the admin offline.
    _ = Ezagent.Cap.authorization_context({:admin, admin()})
    assert {:ok, gen0} = Authority.current_generation(admin())
    assert [old_license] = self_licenses(IdentityCaps.load_persisted(admin()))
    assert Authority.verify_against_current(old_license, admin(), admin())
    _ = Ezagent.Kind.terminate!(admin())

    # Force the AUTHORITATIVE in-txn persist (`Store.persist`) to fail. Because it
    # runs INSIDE `rotate_mint_persist`'s transaction, the failure must roll back
    # rotate + mint too (codex r3 hardening 2).
    Application.put_env(
      :ezagent_domain_identity,
      :admin_rotation_forced_persist_error,
      :forced_persist_failure
    )

    assert {:error, :forced_persist_failure} = AdminKeyRotation.run(io: fn _ -> :ok end)

    # Rolled back: the authority did NOT advance (still gen0), and the OLD license
    # still verifies against the unchanged current generation — no stale-gen window,
    # no post-epoch brick. RED-CHECK: with the persist OUTSIDE the txn (pre-fix), the
    # authority would sit at gen0+1 with the old license stranded.
    assert {:ok, ^gen0} = Authority.current_generation(admin())
    assert Authority.verify_against_current(old_license, admin(), admin())
  end
end
