defmodule EzagentDomainInstanceMessage.Integration.CanonicalAdminBootstrapFreshBootTest do
  @moduledoc """
  #195 — CapBAC canonical-admin bootstrap on fresh boot.

  The canonical admin (`entity://system/user/admin`) holds NO persisted
  capability: its `users.caps_json` is born empty and its `:self_license` is
  deliberately kept OUT of that durable store
  (`Ezagent.EntityCaps.clear_self_license_persisted/1`). Its currency as a
  principal is proven only by the live `:identity`-slice self-license the
  `:identity` Behavior mints while the admin Kind is running.

  The admin Kind spawns LAZILY. On a fresh boot a seed that dispatches AS the
  admin — the default SessionTemplate seed, the cc / role-agent template seeds,
  ConfigEvolve reconcile, the world plugin — runs before anything has referenced
  admin. `Ezagent.Identity.read_held_caps(admin)` is then empty and the admin is
  not executing inside its own authority compartment (`autonomous_current?` is
  false), so the `Ezagent.Cap.authorize/3` principal gate misjudged the admin as
  `:holder_revoked` and the seed failed — hard-crashing dev/prod boot on the
  `default` SessionTemplate invariant.

  Fix (boot-ordering, NOT a gate change): `Ezagent.Cap` bootstraps the admin
  principal Kind at the single act-as-admin issuance chokepoint
  (`authorization_context({:admin, admin})`, reached by every `issue/3` /
  `issue_for_action/3`), so the admin's live self-license exists before the
  downstream principal gate reads it. The authorization gate itself is
  untouched.

  These tests pin the fix AND that it opens no hole:

  * (a) FRESH boot succeeds — the admin seeds the default template while its
    self-license is unpersisted and its Kind is not pre-spawned (the restart /
    `:existed` path — the common fresh-boot-on-an-existing-DB case).
  * (a2) TRUE first boot — the same, but the admin's per-Kind authority was
    never opened (the `:created` path — first-ever boot of a fresh DB), so the
    fix mints the self-license + borns the authority anchor mid-issuance.
  * (b) the gate is NOT weakened — a NON-admin with an empty independent load is
    still `:holder_revoked` (the admin-only bootstrap never leaks to it).
  * (c) the offboarding fence still WINS — a FENCED admin is denied even though
    the fix would otherwise make it current (`principal_fenced?` is checked
    first and wins).
  """

  use EzagentCore.DataCase, async: false

  import Ecto.Query
  import Ezagent.Test.CapHelper

  alias Ezagent.Entity.User
  alias Ezagent.Identity.Offboarding.RevocationFence

  defp admin, do: User.admin_uri()

  defp needed_any,
    do: %{kind: :any, behavior: :any, action: :any, instance: :any, workspace_uri: :any}

  # Reproduce a fresh dev/prod boot for the canonical admin INSIDE the test's
  # sandbox checkout. The test-env boot eagerly spawns the admin Kind (dev/prod
  # does NOT) and its `users.caps_json` picks up a slice — both mask the bug.
  # Clear the persisted caps back to the born-empty state and terminate the live
  # Kind so the admin is effectively unborn: exactly the dev/prod window where a
  # seed runs before anything has referenced admin. The durable per-Kind
  # authority row is intact (as it is once admin has ever been opened; the fix
  # equally covers a never-opened admin, which mints on first spawn).
  #
  # The caps_json write + fence rows roll back with the sandbox, but the GLOBAL
  # admin Kind process does not — re-bootstrap it on exit so we do not strand
  # sibling tests that assume a live boot-seeded admin.
  defp put_admin_in_fresh_boot_state do
    on_exit(fn -> _ = Ezagent.LocalRuntime.ensure_started(User.admin_uri()) end)

    :ok = Ezagent.EntityCaps.UserStore.persist(admin(), [])
    _ = Ezagent.Kind.terminate!(admin())
    Process.sleep(50)

    # Precondition of the fresh-boot state: the principal's INDEPENDENT held-cap
    # load is empty (this is what made the gate misjudge admin as revoked).
    assert Enum.empty?(Ezagent.Identity.read_held_caps(admin())),
           "expected the fresh-boot admin to have an empty independent held-cap load"

    :ok
  end

  test "(a) fresh boot: admin seeds the default template with an unpersisted self-license" do
    put_admin_in_fresh_boot_state()

    workspace_uri =
      Ezagent.URI.new!("workspace://fresh-boot-#{System.unique_integer([:positive])}")

    # Before the fix this returns {:error, :holder_revoked} (the principal gate
    # misjudges the unborn admin) and hard-crashes dev/prod boot on the §3
    # SessionTemplate invariant. The fix bootstraps the admin principal at the
    # issuance chokepoint so the seed authorizes.
    assert :ok =
             EzagentDomainInstanceMessage.Application.seed_default_session_template_now(
               workspace_uri
             )

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

  test "(a2) TRUE first boot (:created): admin whose authority was never opened seeds the default template" do
    # The seed's fix re-opens the admin authority at a FRESH generation-1 inside
    # this test's transaction; after the sandbox rolls back that row no longer
    # exists, so a live admin carrying that phantom generation would corrupt
    # sibling tests. Terminate the admin on exit (BEFORE the rollback) so the
    # next reference re-spawns it cleanly from the restored durable state — never
    # re-spawn here, which would strand the phantom-generation Kind.
    on_exit(fn -> _ = Ezagent.Kind.terminate!(User.admin_uri()) end)

    # Reproduce a genuine first-ever boot (not just a restart): DELETE the
    # `kind_snapshots` row (its `ever_created` marker is what makes a spawn
    # `:created` vs `:existed`; its absence forces the `:identity` Behavior's
    # `init_slice` to MINT a fresh self-license), DELETE the per-Kind authority
    # row so the anchor is not_found and `:created` opens it fresh (retiring
    # leaves the pkey row and collides on re-open), clear the born-empty caps,
    # and terminate the live Kind. The fix's `ensure_started` then hits the
    # `:created` branch, minting the self-license + borning the authority anchor
    # mid-issuance.
    :ok = Ezagent.Ecto.KindSnapshot.delete(URI.to_string(admin()))

    {_deleted, _} =
      EzagentCore.Repo.delete_all(
        from(a in Ezagent.Ecto.KindCapAuthority,
          where: a.uri == ^Ezagent.URI.stable_key(admin())
        )
      )

    :ok = Ezagent.EntityCaps.UserStore.persist(admin(), [])
    _ = Ezagent.Kind.terminate!(admin())
    Process.sleep(50)

    # Precondition of a TRUE first boot: no ever-created marker (→ `:created`)
    # and no current authority anchor for the admin.
    assert Ezagent.Lifecycle.fresh_create?(admin()),
           "expected the admin to look never-opened (:created on next spawn)"

    assert {:error, :not_found} == Ezagent.Cap.Authority.anchor(admin())
    assert Enum.empty?(Ezagent.Identity.read_held_caps(admin()))

    workspace_uri =
      Ezagent.URI.new!("workspace://first-boot-#{System.unique_integer([:positive])}")

    assert :ok =
             EzagentDomainInstanceMessage.Application.seed_default_session_template_now(
               workspace_uri
             )
  end

  test "(b) gate not weakened: a NON-admin with an empty independent load is still :holder_revoked" do
    # Bootstrap the admin to currency exactly as any admin issuance would, so
    # this proves the fix is NARROW: it never leaks currency to a non-admin.
    _ = Ezagent.Cap.authorization_context({:admin, admin()})

    non_admin =
      Ezagent.URI.new!("entity://team-alpha/user/nobody-#{System.unique_integer([:positive])}")

    # Never spawned, no users row → empty independent load, not autonomous.
    assert Enum.empty?(Ezagent.Identity.read_held_caps(non_admin))

    # Presenting an inline candidate can never satisfy the principal gate (MF2);
    # the empty independent load is fail-closed and the admin-only bootstrap
    # does not apply to this holder.
    inline = cap(kind: :any, behavior: :any, instance: :any, workspace_uri: :any)

    assert {:error, :holder_revoked} =
             Ezagent.Cap.authorize(non_admin, [inline], needed_any())
  end

  test "(c) fence wins: a FENCED admin is denied even though the fix would make it current" do
    # Bootstrap the admin to currency (the fix path) FIRST, so the denial below
    # can only come from the fence — not from a lack of currency.
    _ = Ezagent.Cap.authorization_context({:admin, admin()})

    refute Enum.empty?(Ezagent.Identity.read_held_caps(admin())),
           "precondition: the bootstrapped admin is current (non-empty held-cap load)"

    :ok = RevocationFence.enroll([admin()])
    assert RevocationFence.fenced?(admin())

    inline = cap(kind: :any, behavior: :any, instance: :any, workspace_uri: :any)

    # `principal_fenced?` is the first element of the gate tuple and wins over
    # any currency the bootstrap conferred.
    assert {:error, :holder_revoked} =
             Ezagent.Cap.authorize(admin(), [inline], needed_any())
  end
end
