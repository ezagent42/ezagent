defmodule Ezagent.Cap.RevocationEpochTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.RevocationEpoch

  setup do
    previous = Application.get_env(:ezagent_core, :cap_revocation_epoch_override)
    Application.delete_env(:ezagent_core, :cap_revocation_epoch_override)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:ezagent_core, :cap_revocation_epoch_override)
      else
        Application.put_env(:ezagent_core, :cap_revocation_epoch_override, previous)
      end

      Application.delete_env(:ezagent_core, :cap_revocation_epoch_force_read_error)
    end)

    :ok
  end

  test "ships inactive and activates monotonically" do
    assert RevocationEpoch.status() == :inactive
    refute RevocationEpoch.active?()

    assert :ok = RevocationEpoch.activate()
    assert :ok = RevocationEpoch.activate()
    assert RevocationEpoch.status() == :active
    assert RevocationEpoch.active?()
  end

  test "an unreadable epoch is unknown and denies active state" do
    Application.put_env(:ezagent_core, :cap_revocation_epoch_force_read_error, true)

    assert RevocationEpoch.status() == :unknown
    refute RevocationEpoch.active?()
  end

  test "test override exposes all three states without changing durable state" do
    for state <- [:inactive, :active, :unknown] do
      Application.put_env(:ezagent_core, :cap_revocation_epoch_override, state)
      assert RevocationEpoch.status() == state
    end
  end
end
