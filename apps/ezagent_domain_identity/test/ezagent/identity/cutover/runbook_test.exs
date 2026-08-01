defmodule Ezagent.Identity.Cutover.RunbookTest do
  @moduledoc """
  #189 PR-3 (FIX 5) release-runnable extraction — the cutover operator flow
  INTERLOCK, exercised directly against `Ezagent.Identity.Cutover.Runbook` (the
  module both `mix ezagent.identity.cutover` and
  `EzagentCore.Release.identity_cutover/1` now delegate to).

  Complements `Ezagent.Identity.CutoverTest`, which pins the MIX TASK's own
  observable CLI contract (messages, exit code, stdout/stderr split) unchanged.
  This suite proves the underlying decision logic end-to-end — INCLUDING the
  step `Ezagent.Identity.CutoverTest` never exercises: the cross-domain session
  self-license migration, dispatched via `apply/3` on
  `Ezagent.Socialware.SessionSelfLicenseMigration` (a DIFFERENT umbrella app —
  `ezagent_domain_session` — reached with no compile dependency; see the
  Runbook moduledoc).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.{KindBase, SelfLicense}
  alias Ezagent.Cap
  alias Ezagent.Capability
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.IdentityCaps.Store
  alias Ezagent.Identity.{Cutover, FleetParity}
  alias Ezagent.Identity.Cutover.Runbook

  test "REFUSE on parity-incomplete: a phantom store row survives the Runbook's own backfill" do
    # NOTE: a plain "create a legacy user, don't backfill it" setup does NOT
    # produce incompleteness here — the Runbook's OWN step 1 backfills every
    # enumerated legacy principal (including this one) before the barrier
    # runs. A discrepancy that survives backfill needs a store row with NO
    # legacy backing at all (`phantom_active` — mirrors
    # `Ezagent.Identity.FleetParityTest`'s test of the same name): backfill
    # only enumerates legacy sources, so it never touches/corrects a phantom.
    agent = agent_uri("phantom")
    assert :ok = Store.persist(agent, licensed_caps(agent, []))
    assert Store.status(agent) == :active

    refute Cutover.activated?()

    assert {:refused, {:parity_incomplete, result}} = run_quiet(dry_run: false)
    refute result.complete
    assert {:phantom_active, URI.to_string(agent)} in result.discrepancies
    refute Cutover.activated?()
  end

  test "REFUSE on forced backfill error (the seam) — aborts BEFORE session migration / barrier" do
    forced_uri = "entity://forced/agent/runbook-backfill-failure"
    Application.put_env(:ezagent_domain_identity, :backfill_force_error_uri, forced_uri)
    on_exit(fn -> Application.delete_env(:ezagent_domain_identity, :backfill_force_error_uri) end)

    io =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:refused, {:backfill_errors, errors}} =
                 Runbook.run(dry_run: false, io: fn _ -> :ok end)

        assert [{^forced_uri, :forced_backfill_error}] = errors
      end)

    # The abort is the BACKFILL step (its exact, unique messages) …
    assert io =~ "BACKFILL FAILED"
    assert io =~ "the backfill is INCOMPLETE"
    assert io =~ "runbook-backfill-failure"

    # … and neither the session migration nor the parity barrier was ever
    # reached (their messages are absent — the `with` chain short-circuited).
    refute io =~ "session self-license migration"
    refute io =~ "the store is NOT a parity-correct mirror"

    refute Cutover.activated?()
  end

  test "REFUSE on forced session-migration error — aborts BEFORE the parity barrier" do
    # Reuse the EXISTING `p1_forced_shadow_failure_uris` seam
    # (`Ezagent.IdentityCaps.Store.persist/2`, already exercised cross-domain by
    # `Ezagent.Socialware.SessionSelfLicenseMigrationTest`'s "RETRYABLE" test)
    # rather than adding a new seam: it forces the session migration's
    # AUTHORITATIVE store write to fail for one URI, which surfaces as a
    # per-row `{:error, reason}` in `SessionSelfLicenseMigration.run/1`'s
    # result — exactly the shape the Runbook's `run_session_migration/3` must
    # abort on, the same way `abort_on_backfill_errors/2` aborts on a backfill
    # error.
    session = session_uri("session-migration-failure")
    write_pre_cutover_session(session)

    store_key = session |> Ezagent.URI.instance() |> URI.to_string()
    Application.put_env(:ezagent_domain_identity, :p1_forced_shadow_failure_uris, [store_key])

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_identity, :p1_forced_shadow_failure_uris)
    end)

    io =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:refused, {:session_migration_errors, errors}} =
                 Runbook.run(dry_run: false, io: fn _ -> :ok end)

        assert [{session_uri_str, {:p1_forced_shadow_failure, ^store_key}}] = errors
        assert session_uri_str == URI.to_string(session)
      end)

    # The abort is the SESSION-MIGRATION step (its exact, unique message) …
    assert io =~ "session(s) FAILED to migrate"

    # … and the parity barrier was NEVER reached (its refuse message is
    # absent) — the `with` chain short-circuited BEFORE `FleetParity.check/0`.
    refute io =~ "the store is NOT a parity-correct mirror"

    refute Cutover.activated?()
  end

  test "DRY-RUN does not activate even when parity is already complete" do
    user = user_uri("dry-run-complete")
    caps = licensed_caps(user, [])
    assert {:ok, _} = Ezagent.Users.create(user, nil, caps)
    # Pre-populate completeness DIRECTLY (bypassing the Runbook), so this test
    # isolates ONE thing: given `complete: true`, does `dry_run: true` refrain
    # from activating.
    assert {:ok, :active} = Store.backfill(user, caps)
    assert FleetParity.check().complete

    refute Cutover.activated?()
    assert :dry_run = run_quiet(dry_run: true)
    refute Cutover.activated?()
  end

  test "ACTIVATE on complete — end-to-end, INCLUDING the cross-domain session migration" do
    user = user_uri("activate")
    caps = licensed_caps(user, [])
    assert {:ok, _} = Ezagent.Users.create(user, nil, caps)

    # A genuinely pre-cutover session (kind_base captured WITHOUT SelfLicense,
    # real chat state) — this is what proves the Runbook's `apply/3` dispatch
    # to `Ezagent.Socialware.SessionSelfLicenseMigration` (a different
    # umbrella app) actually RAN, rather than a vacuous zero-row no-op.
    session = session_uri("activate")
    write_pre_cutover_session(session)
    refute SelfLicense in captured_behaviors(session)

    refute Cutover.activated?()

    assert :activated = run_quiet(dry_run: false)

    assert Cutover.activated?()
    assert Store.status(user) == :active
    assert Store.status(session) == :active
    assert SelfLicense in captured_behaviors(session)
  end

  # ---- helpers ----------------------------------------------------------

  defp run_quiet(opts) do
    Runbook.run(Keyword.merge([io: fn _ -> :ok end, io_err: fn _ -> :ok end], opts))
  end

  defp user_uri(suffix),
    do: URI.new!("entity://cutover-runbook/user/#{suffix}-#{System.unique_integer([:positive])}")

  defp agent_uri(suffix),
    do: URI.new!("entity://cutover-runbook/agent/#{suffix}-#{System.unique_integer([:positive])}")

  defp session_uri(suffix),
    do:
      Ezagent.URI.new!("session://cutover-runbook/default/#{suffix}-#{System.unique_integer([:positive])}")

  defp licensed_caps(receiver, caps), do: [self_license(receiver) | caps]

  # Mirrors `Ezagent.Identity.FleetParityTest`'s helper of the same name.
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

  # Mirrors `Ezagent.Socialware.SessionSelfLicenseMigrationTest`'s helper of the
  # same name — a genuinely pre-cutover captured behavior list (built
  # EXPLICITLY without SelfLicense, not from today's `Session.behaviors/0`).
  defp write_pre_cutover_session(uri) do
    uri_str = URI.to_string(uri)
    ws = uri |> Ezagent.URI.workspace_of() |> URI.to_string()

    state = %{
      kind_base: %{state: %{behaviors: [Ezagent.ActionSet.Session]}},
      chat: %{messages: []}
    }

    binary = state |> Ezagent.Kind.Snapshot.strip_transients() |> :erlang.term_to_binary()

    {:ok, _} = KindSnapshot.upsert(uri_str, "session", binary, 0, ws, mark_ever_created: true)
  end

  defp captured_behaviors(uri) do
    {:ok, state} = KindSnapshot.decode_state(KindSnapshot.get(URI.to_string(uri)))
    KindBase.behaviors_in_slice(Map.get(state, KindBase.state_slice())) || []
  end
end
