defmodule Ezagent.Identity.CutoverTest do
  # #189 PR-3 FIX 5 — the persisted cutover EPOCH. `async: false`: these tests
  # drive the REAL DB-backed epoch and mutate the process-global override /
  # forced-read-error app env, so they must not interleave with the rest of the
  # suite (which relies on the override being force-active).
  use EzagentCore.DataCase, async: false

  alias Ezagent.Identity.Cutover

  setup do
    # The suite forces the epoch active via `:identity_cutover_active_override`.
    # These tests exercise the DB-backed `active?/0`, so clear the override for
    # their duration and restore it after. `:identity_cutover_pt_cache` is false
    # in test, so no sticky `:persistent_term` `true` leaks across tests.
    prev = Application.get_env(:ezagent_domain_identity, :identity_cutover_active_override)
    Application.delete_env(:ezagent_domain_identity, :identity_cutover_active_override)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:ezagent_domain_identity, :identity_cutover_active_override)
        v -> Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, v)
      end

      Application.delete_env(:ezagent_domain_identity, :identity_cutover_force_read_error)
    end)

    :ok
  end

  test "the app-env override short-circuits the DB read (true / false both win)" do
    Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, true)
    assert Cutover.active?()

    Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, false)
    refute Cutover.active?()

    Application.delete_env(:ezagent_domain_identity, :identity_cutover_active_override)
  end

  test "PRE-EPOCH (no row) is inactive; activate/0 flips it active (DB-backed)" do
    refute Cutover.activated?()
    refute Cutover.active?()

    assert :ok = Cutover.activate()

    assert Cutover.activated?()
    assert Cutover.active?()
  end

  test "activate/0 is idempotent — the epoch is monotone" do
    assert :ok = Cutover.activate()
    assert :ok = Cutover.activate()
    assert Cutover.activated?()
    assert Cutover.active?()
  end

  test "FAILS CLOSED — an UNREADABLE epoch resolves to inactive (pre-epoch legacy)" do
    assert :ok = Cutover.activate()
    assert Cutover.active?()

    # An unreadable epoch (DB error / missing table on a half-migrated node) must
    # NEVER be read as active: `active?/0` denies even though a row exists. New
    # store-authoritative code therefore never authorizes from the store on an
    # unreadable epoch.
    Application.put_env(:ezagent_domain_identity, :identity_cutover_force_read_error, true)
    refute Cutover.active?()
  end
end
