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
