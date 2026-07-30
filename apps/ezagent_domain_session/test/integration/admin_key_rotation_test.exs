defmodule EzagentDomainInstanceMessage.Integration.AdminKeyRotationTest do
  @moduledoc """
  #1627 B1-hybrid — the sanctioned manual admin key-rotation operator command
  (`Ezagent.Identity.AdminKeyRotation`). The admin is structurally un-killable, so
  rotation is the ONE way to advance the root's generation; it rotates the
  authority AND re-mints the self-license under the new generation atomically (one
  transaction under the authority-row lock) — no stale-generation admin window.

  This spawns + rotates + terminates the VM-GLOBAL genesis-admin singleton, so it
  runs ALONE in the isolated `session_boot_seed` CI shard (`@moduletag
  :real_boot_seed_path`, excluded from the default suite) rather than corrupting
  sibling tests that depend on the live admin.
  """

  use EzagentCore.DataCase, async: false

  @moduletag :real_boot_seed_path

  alias Ezagent.Cap.Authority
  alias Ezagent.Capability
  alias Ezagent.Entity.User
  alias Ezagent.EntityCaps
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
    assert [license] = self_licenses(EntityCaps.load_persisted(admin()))
    assert Authority.verify_against_current(license, admin(), admin())
  end
end
