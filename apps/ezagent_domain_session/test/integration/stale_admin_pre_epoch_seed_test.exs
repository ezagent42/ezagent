defmodule EzagentDomainInstanceMessage.Integration.StaleAdminPreEpochSeedTest do
  @moduledoc """
  Canary boot regression (deploy run 30456630379) — the high-fidelity seed path.

  A canary booted the NEW build against a REFLOWED prod DB whose genesis admin
  (`entity://system/user/admin`) authority had been ROTATED since its self-license
  was minted, so the persisted self-license was STALE-GENERATION. The cutover
  epoch was `:inactive` (a genuine pre-cutover node — no `identity_cutover` row).
  The very first cap-authorized boot write — the `default` SessionTemplate seed,
  dispatched AS the admin — then `holder_revoked`-ed (the admin's gen-gated
  held-cap load was EMPTY), hard-crashing `§3` boot.

  This mirrors `CanonicalAdminBootstrapFreshBootTest`, but the admin here holds a
  STALE (not merely absent) self-license, under a DEFINITIVE `:inactive` epoch —
  the exact combination `#195` (born-empty admin) and the test/dev forced-active
  epoch both mask. The fix (`ActionSet.Identity`'s pre-epoch gen-reboot re-mint)
  restores the legacy self-operating-authority contract: pre-epoch, a live,
  authority-history-backed, non-tombstoned, non-fenced principal re-mints a
  current-generation self-license at boot, so the seed authorizes.
  """

  use EzagentCore.DataCase, async: false

  # EXCLUDED from the default suite: this test drives the REAL boot seed, which
  # `regenesis`-es the VM-GLOBAL genesis-admin singleton and spawns a durable
  # SessionTemplate Kind whose async snapshot persist can escape the Ecto sandbox
  # — both corrupt sibling tests (the hazard `CanonicalAdminBootstrapFreshBootTest`
  # documents). It is a standalone real-seed-path regression, run explicitly:
  #   mix test <this file> --include real_boot_seed_path
  # The sandboxed `Ezagent.PreEpochBootRemintTest` is the in-suite regression.
  @moduletag :real_boot_seed_path

  alias Ezagent.Cap.Authority
  alias Ezagent.Entity.User

  defp admin, do: User.admin_uri()

  test "pre-epoch: admin with a STALE-generation self-license still seeds the default template" do
    # The seed rotates the admin authority inside this test's sandbox
    # transaction; after rollback a live admin carrying that phantom generation
    # would corrupt sibling tests. Terminate on exit WITHOUT re-spawning (mirrors
    # `CanonicalAdminBootstrapFreshBootTest` (a2)): the next reference re-spawns
    # the admin cleanly from the sandbox-restored durable state. Never re-spawn
    # here — that would strand the phantom-generation Kind.
    on_exit(fn -> _ = Ezagent.Kind.terminate!(admin()) end)

    # 1. Bring the admin to currency exactly as any admin issuance would (the
    #    `#195` bootstrap), so it holds a CURRENT-generation self-license.
    _ = Ezagent.Cap.authorization_context({:admin, admin()})

    refute Enum.empty?(Ezagent.Identity.read_held_caps(admin())),
           "precondition: the bootstrapped admin is a current principal"

    # 2. ROTATE the admin authority WITHOUT re-minting (an INTERRUPTED rotation —
    #    a bare `regenesis(admin)` is rejected post-#1627 as the root is
    #    un-killable). Its persisted self-license is now STALE-GENERATION (the
    #    reflow/interrupted-rotation canary condition), and its independent
    #    held-cap load gen-gates to EMPTY.
    assert {:ok, _bumped} = Authority.rotate_root_generation(admin(), :user)
    _ = Ezagent.Kind.terminate!(admin())
    Process.sleep(50)

    assert Enum.empty?(Ezagent.Identity.read_held_caps(admin())),
           "the stale-generation admin gen-gates to an empty held-cap load"

    workspace_uri =
      Ezagent.URI.new!("workspace://stale-admin-#{System.unique_integer([:positive])}")

    # 3. Seed the default template AS the admin, under a DEFINITIVE :inactive
    #    epoch. Before the fix this returns {:error, :holder_revoked} and §3
    #    hard-crashes boot; the pre-epoch re-mint restores the admin's currency
    #    at spawn so the seed authorizes.
    with_epoch(:inactive, fn ->
      assert :inactive == Ezagent.Identity.Cutover.status()

      assert :ok =
               EzagentDomainInstanceMessage.Application.seed_default_session_template_now(
                 workspace_uri
               )
    end)

    # The seeded template landed under the requested workspace.
    assert Ezagent.Ecto.KindSnapshot.list_in_workspace(URI.to_string(workspace_uri))
           |> Enum.any?(fn snap ->
             is_binary(snap.uri) and
               String.starts_with?(
                 snap.uri,
                 "template://#{Ezagent.URI.name!(workspace_uri)}/session/default@"
               )
           end)
  end

  # Drive the cutover epoch deterministically via the app-env override (the same
  # seam `config/test.exs` uses), restoring the suite's forced-active default.
  defp with_epoch(status, fun) when status in [:active, :inactive] do
    key = :identity_cutover_active_override
    previous = Application.get_env(:ezagent_domain_identity, key, :unset)
    Application.put_env(:ezagent_domain_identity, key, status == :active)

    try do
      fun.()
    after
      case previous do
        :unset -> Application.delete_env(:ezagent_domain_identity, key)
        value -> Application.put_env(:ezagent_domain_identity, key, value)
      end
    end
  end
end
