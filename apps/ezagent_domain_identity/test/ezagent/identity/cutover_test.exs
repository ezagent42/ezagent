defmodule Ezagent.Identity.CutoverTest do
  # #189 PR-3 FIX 5 — the persisted cutover EPOCH. `async: false`: these tests
  # drive the REAL DB-backed epoch and mutate the process-global override /
  # forced-read-error app env, so they must not interleave with the rest of the
  # suite (which relies on the override being force-active).
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap
  alias Ezagent.Capability
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

  test "FAILS CLOSED — an UNREADABLE epoch resolves to :unknown, DISTINCT from pre-epoch :inactive" do
    assert :ok = Cutover.activate()
    assert Cutover.active?()
    assert Cutover.status() == :active

    # #189 PR-3 FINAL (ITEM 3) — an unreadable epoch (DB error / missing table on
    # a half-migrated node) resolves to `:unknown`, NOT the definitive `:inactive`
    # a genuine pre-cutover node reports. The distinction is the whole point:
    # `:inactive` selects the legacy plane, `:unknown` must fail CLOSED (deny
    # reads / reject mutations). `active?/0` denies even though a row exists.
    Application.put_env(:ezagent_domain_identity, :identity_cutover_force_read_error, true)
    assert Cutover.status() == :unknown
    refute Cutover.active?()
  end

  test "a DEFINITIVE pre-cutover node (no row, DB reachable) is :inactive, not :unknown" do
    refute Cutover.activated?()
    assert Cutover.status() == :inactive
    refute Cutover.active?()
  end

  describe "cutover task INTERLOCK (refuse-unless-complete)" do
    alias Mix.Tasks.Ezagent.Identity.Cutover, as: Task

    test "an INCOMPLETE barrier ALWAYS refuses — the epoch is never activated on divergence" do
      # The one operator safety interlock: no matter the dry-run flag, an
      # incomplete parity result must NOT activate.
      assert Task.decide(%{complete: false}, false) == :refuse
      assert Task.decide(%{complete: false}, true) == :refuse
    end

    test "a COMPLETE barrier activates (live) or reports (dry-run), never the reverse" do
      assert Task.decide(%{complete: true}, false) == :activate
      assert Task.decide(%{complete: true}, true) == :dry_run
    end

    test "the REAL cutover task ABORTS AT THE BACKFILL STEP on a failing backfill, before parity (ITEM 2)" do
      # A fresh node: no epoch row yet. (`activated?/0` reads the real DB row —
      # the suite's `active?` override never writes one.)
      refute Cutover.activated?()

      # Force a deterministic backfill error — the real-world case is a failed
      # authority-history adoption, which pre-fix only PRINTED and returned
      # normally, letting the interlock proceed to the parity barrier + activation.
      Application.put_env(
        :ezagent_domain_identity,
        :backfill_force_error_uri,
        "entity://forced/agent/backfill-failure"
      )

      on_exit(fn -> Application.delete_env(:ezagent_domain_identity, :backfill_force_error_uri) end)

      # Run the REAL task (not the pure `decide/2`) and capture its diagnostics.
      # NON-VACUOUS DISCRIMINATOR: in a fresh sandbox the parity barrier would
      # ALSO refuse (the store is not a full legacy mirror), so `activated? ==
      # false` alone proves nothing. Instead we pin the abort to the BACKFILL
      # STEP: the interlock consumes the failing backfill result and aborts
      # BEFORE `FleetParity.check/0` ever runs. Pre-fix the backfill result was
      # ignored, the task fell through to parity, and the epoch's fate hung on
      # the parity outcome — so the interlock-specific messages below are absent
      # and the parity-refuse message is present.
      io =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:shutdown, 1} = catch_exit(Task.run([]))
        end)

      # The abort is the BACKFILL interlock (its exact, unique messages) …
      assert io =~ "BACKFILL FAILED"
      assert io =~ "the backfill is INCOMPLETE"
      assert io =~ "forced/agent/backfill-failure"

      # … and the parity barrier was NEVER reached (its refuse message is absent).
      refute io =~ "the store is NOT a parity-correct mirror"

      # The epoch is LEFT ABSENT.
      refute Cutover.activated?()
    end

    test "the REAL cutover task ACTIVATES on complete — pins the NEW 3-step CLI messages" do
      # #189 release-runnable extraction (Ezagent.Identity.Cutover.Runbook) made
      # the previously-undocumented session self-license migration step a real,
      # printed step: the labels changed from "Step 1/2" / "Step 1b" / "Step 2/2"
      # to "Step 1/3" / "Step 2/3" / "Step 3/3" (there really are three steps
      # now — backfill, session migration, activate). This is a DELIBERATE,
      # documented CLI output contract change (see PR #1625), NOT a silent
      # regression — pin the new messages here so they carry the same
      # protection the old ones would have.
      user = user_uri("cutover-cli-activate")
      caps = licensed_caps(user, [])
      assert {:ok, _} = Ezagent.Users.create(user, nil, caps)

      refute Cutover.activated?()

      io =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Task.run([])
        end)

      assert io =~ "=== #189 identity-plane cutover ==="
      assert io =~ "Step 1/3 — backfill"
      assert io =~ "Step 2/3 — session self-license migration"
      assert io =~ "Step 3/3 — COMPLETE. Activating the cutover epoch"
      assert io =~ "EPOCH ACTIVE — the store is now authoritative for identity reads."

      assert Cutover.activated?()
    end
  end

  # ---- helpers (mirror Ezagent.Identity.Cutover.RunbookTest) ---------------

  defp user_uri(suffix),
    do: URI.new!("entity://cutover-cli/user/#{suffix}-#{System.unique_integer([:positive])}")

  defp licensed_caps(receiver, caps), do: [self_license(receiver) | caps]

  defp self_license(receiver) do
    {:ok, type} = Ezagent.URI.type(receiver)
    kind = String.to_existing_atom(type)
    {:ok, authority} = Cap.Authority.open(receiver, kind)

    requested =
      Capability.cap(
        kind,
        Ezagent.ActionSet.Identity,
        :self_license,
        receiver,
        Ezagent.URI.workspace_of(receiver)
      )

    intent = Ezagent.Cap.Grant.freeze(receiver, receiver, receiver, requested)

    {:ok, license} =
      Cap.Authority.with_current(authority, fn ->
        Cap.Authority.issue_self_license_current(intent)
      end)

    license
  end
end
