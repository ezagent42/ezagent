defmodule EzagentCore.ReleaseTest do
  @moduledoc """
  #189 — `EzagentCore.Release.identity_cutover/1`, the RELEASE-node entrypoint
  (`bin/ezagent eval "EzagentCore.Release.identity_cutover()"`) for the
  identity-plane cutover epoch, dispatched via `apply/3` onto
  `Ezagent.Identity.Cutover.Runbook` (a module DEFINED in a different
  umbrella app — `ezagent_domain_identity` — so `ezagent_core`, a layer BELOW
  every domain app, must not compile-depend on it; see `@cutover_runbook` in
  `lib/ezagent_core/release.ex`).

  This is the ONE behavior that differs between the mix task and the release
  entrypoint: the mix task sets a process exit status on `{:refused, _}`; the
  release entrypoint has no Mix exit-status convention to hook, so it `raise`s
  instead — that's what makes `bin/ezagent eval` fail loudly (nonzero exit) on
  divergence. The refusal DECISION itself is already covered by
  `Ezagent.Identity.Cutover.Runbook`'s own test suite; this suite covers only
  the release-specific raise/return wiring.
  """

  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — dispatches (via `apply/3`, same as the
  # production code path) into `ezagent_domain_identity` modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.Cap
  alias Ezagent.Capability
  alias Ezagent.EntityCaps.Store
  alias Ezagent.Identity.Cutover

  test "REFUSED cutover RAISES (release has no Mix exit-status hook)" do
    forced_uri = "entity://forced/agent/release-eval-backfill-failure"
    Application.put_env(:ezagent_domain_identity, :backfill_force_error_uri, forced_uri)
    on_exit(fn -> Application.delete_env(:ezagent_domain_identity, :backfill_force_error_uri) end)

    assert_raise RuntimeError, ~r/identity cutover REFUSED/, fn ->
      EzagentCore.Release.identity_cutover(io: quiet(), io_err: quiet())
    end

    refute Cutover.activated?()
  end

  test "COMPLETE + dry_run: true returns :dry_run without raising or activating" do
    # Hermetic precondition (was: bare `assert
    # Ezagent.Identity.FleetParity.check().complete`, which reads the AMBIENT,
    # unscoped durable fleet — every user, snapshot-backed entity and session
    # in the DB, not just what this test creates; see the FleetParity
    # moduledoc). Reproduced across random `mix test` seeds: OTHER
    # `ezagent_core` suites legitimately grant/persist self-licenses for
    # system/template fixtures (e.g. `entity://system/agent/cc-orchestrator`,
    # `session://system/default/main`) as a side effect of testing unrelated
    # behavior; the Store's shadow-write for one of those can outlive the
    # durable `:identity` slice a `check/0` re-derives it from, which the
    # barrier correctly reports as `phantom_active` — a class `Backfill`
    # deliberately never self-heals (`Ezagent.Identity.Cutover.RunbookTest`
    # "REFUSE on parity-incomplete" pins the same non-healing contract). So
    # this test cannot assume the ambient fleet is parity-complete; it must
    # make it so, the same corrective actions a real cutover operator would
    # take, before it exercises the dry-run CONTRACT against that
    # (now-controlled) fleet.
    reconcile_ambient_fleet_parity!()

    user = user_uri("dry-run")
    caps = licensed_caps(user, [])
    assert {:ok, _} = Ezagent.Users.create(user, nil, caps)
    assert {:ok, :active} = Store.backfill(user, caps)
    assert Ezagent.Identity.FleetParity.check().complete

    refute Cutover.activated?()

    assert :dry_run =
             EzagentCore.Release.identity_cutover(dry_run: true, io: quiet(), io_err: quiet())

    refute Cutover.activated?()
  end

  # ---- helpers (mirror Ezagent.Identity.Cutover.RunbookTest) -------------

  # Reconcile the REAL ambient durable fleet to parity-complete, using only
  # the same sanctioned corrective actions the Runbook/an operator would run
  # — never a shortcut that fakes completeness:
  #
  #   1. A real (non-dry-run) `Ezagent.Identity.Backfill.run/1` over the
  #      WHOLE fleet — heals every FORWARD-direction discrepancy class
  #      (`missing_active_row`, `stale_active`, `absent_license_invalid`,
  #      `caps_mismatch`, `unexpected_non_active`) for any legacy holder it
  #      can enumerate.
  #   2. Any remaining `phantom_active` (a store-only row with NO legacy
  #      backing — the one class backfill cannot touch by design) is
  #      revoked via `Store.revoke_provisioning/1`, same as an operator
  #      reconciling a stale shadow row before a real cutover.
  #
  # Any OTHER surviving discrepancy kind (e.g. `legacy_read_error`,
  # `session_missing_identity`) has no sanctioned fix here and `flunk`s
  # loudly with the full list — this suite must never silently proceed on
  # unreconciled ambient state.
  defp reconcile_ambient_fleet_parity! do
    {:ok, _results} = Ezagent.Identity.Backfill.run(io: quiet(), io_err: quiet())

    result = Ezagent.Identity.FleetParity.check()

    unhealed =
      Enum.reject(result.discrepancies, fn
        {:phantom_active, uri_str} -> :ok == Store.revoke_provisioning(uri_str)
        _other -> false
      end)

    if unhealed != [] do
      flunk(
        "ReleaseTest cannot reconcile the ambient fleet to parity-complete — " <>
          "unhandled discrepancy kind(s): #{inspect(unhealed)}"
      )
    end

    :ok
  end

  defp quiet, do: fn _ -> :ok end

  defp user_uri(suffix),
    do: URI.new!("entity://release-eval/user/#{suffix}-#{System.unique_integer([:positive])}")

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
