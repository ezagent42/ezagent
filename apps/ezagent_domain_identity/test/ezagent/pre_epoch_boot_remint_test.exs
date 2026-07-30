defmodule Ezagent.PreEpochBootRemintTest do
  @moduledoc """
  Canary boot regression (deploy run 30456630379) — the PRE-EPOCH gen-reboot
  self-license re-mint predicate (`Ezagent.Identity.PreEpochRemint`).

  The default-SessionTemplate `§3` boot seed dispatches AS the genesis admin,
  whose self-license gen-gates to `[]` when its authority was rotated since the
  mint (or predates the license) — `:holder_revoked`, boot hard-fails. The re-mint
  restores the admin's currency PRE-EPOCH.

  ## Why this cannot resurrect a revoked principal (the security core)

  Generation rotation IS a revocation mechanism (`Cap.revoke_all_to/2`,
  `DeleteUser.invalidate_one/2`), and `revoke_all_to` leaves NO durable
  kill-witness (gen-bump only — no store downgrade, no fence), so a killed
  principal's footprint is indistinguishable from a legacy stale-license one. The
  re-mint is therefore gated on WHO — the **canonical genesis admin** (the
  authority root, re-ensured every boot, for which "revocation" is undefined) —
  NOT on the absence of kill-markers. Every non-root principal is denied, so a
  killed regular/agent principal is never resurrected. Store-row-not-revoked +
  not-fenced are FAIL-CLOSED defense-in-depth.

  These drive `ActionSet.Identity.activate/2` DIRECTLY (the same deterministic,
  sandbox-safe seam `SelfLicenseMintOnCreateTest` uses — no actor-spawn/async
  timing), and use the `:pre_epoch_remint_root_uri` config seam to point the
  "authority root" at a FABRICATED system principal so the eligible path runs
  without mutating the VM-global admin singleton.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Cap.Authority
  alias Ezagent.EntityCaps.Store
  alias Ezagent.Identity.Offboarding.RevocationFence
  alias EzagentCore.Repo

  describe "PRE-EPOCH (:inactive) — the authority root heals" do
    test "the authority root re-mints a CURRENT-generation self-license at boot" do
      root = system_root("heal")

      caps =
        with_root(root, fn ->
          {stale, gen2} = gen_bumped(root, :user)

          # Precondition: the rehydrated slice's self-license is STALE.
          assert [stale_lic] = self_licenses(stale.caps)
          refute Authority.verify_against_current(stale_lic, root, root)

          with_epoch(:inactive, fn -> activate_caps(gen2, stale, root) end)
        end)

      assert [relicensed] = self_licenses(caps)
      assert Authority.verify_against_current(relicensed, root, root)
      assert length(self_licenses(caps)) == 1
    end
  end

  describe "anti-resurrection — a killed / non-root principal is NEVER re-minted" do
    test "BLOCKER: a gen-bumped NON-root principal (revoke_all_to / delete kill) is NOT re-minted" do
      # Config root stays the DEFAULT genesis admin; this regular agent is not the
      # root, so a generation bump (the exact `revoke_all_to` / `delete_user` kill
      # footprint) leaves it inert — no re-mint, no resurrection.
      agent = regular_agent("killed")
      {stale, gen2} = gen_bumped(agent, :agent)

      caps = with_epoch(:inactive, fn -> activate_caps(gen2, stale, agent) end)

      refute has_current_self_license?(caps, agent)
    end

    test "a FENCED root is NOT re-minted (offboarding fence wins, fail-closed)" do
      root = system_root("fenced")

      caps =
        with_root(root, fn ->
          {stale, gen2} = gen_bumped(root, :user)
          :ok = RevocationFence.enroll([root])
          assert RevocationFence.fenced?(root)
          with_epoch(:inactive, fn -> activate_caps(gen2, stale, root) end)
        end)

      refute has_current_self_license?(caps, root)
    end

    test "a root with a :revoked_unprovisioned store row is NOT re-minted (durable ledger)" do
      root = system_root("revoked")

      caps =
        with_root(root, fn ->
          {stale, gen2} = gen_bumped(root, :user)
          insert_store_row(root, "revoked_unprovisioned")
          assert Store.status(root) == :revoked_unprovisioned
          with_epoch(:inactive, fn -> activate_caps(gen2, stale, root) end)
        end)

      refute has_current_self_license?(caps, root)
    end

    test "a root whose store row is UNREADABLE is NOT re-minted (fail-closed store read)" do
      root = system_root("read-error")

      caps =
        with_root(root, fn ->
          {stale, gen2} = gen_bumped(root, :user)

          with_forced_store_read_error(root, fn ->
            assert Store.status_result(root) == :error
            with_epoch(:inactive, fn -> activate_caps(gen2, stale, root) end)
          end)
        end)

      refute has_current_self_license?(caps, root)
    end
  end

  describe "POST-EPOCH (:active) — mint-once / anti-resurrection UNCHANGED (control)" do
    test "the authority root is NOT re-minted post-epoch (a gen-bump IS a revocation)" do
      root = system_root("post-epoch")

      caps =
        with_root(root, fn ->
          {stale, gen2} = gen_bumped(root, :user)
          with_epoch(:active, fn -> activate_caps(gen2, stale, root) end)
        end)

      refute has_current_self_license?(caps, root)
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  # A FABRICATED system-scoped principal that the config seam points the
  # "authority root" at — sandbox-safe (never the VM-global admin).
  defp system_root(suffix),
    do: Ezagent.URI.user(:system, "pre-epoch-root-#{suffix}-#{System.unique_integer([:positive])}")

  defp regular_agent(suffix),
    do: Ezagent.URI.agent("team-alpha", "pre-epoch-#{suffix}-#{System.unique_integer([:positive])}")

  # Mint a self-license at generation 1, then rotate to generation 2 — so the
  # rehydrated slice carries a STALE-generation self-license. Returns the stale
  # `:identity` slice and the CURRENT (generation-2) authority the boot opens.
  defp gen_bumped(uri, kind) do
    {:ok, gen1} = Authority.open(uri, kind)

    {:ok, %{caps: caps}} =
      Authority.with_current(gen1, fn ->
        Ezagent.ActionSet.Identity.create(%{uri: uri, initial_caps: [], create_freshness: :created})
      end)

    assert [_gen1_license] = self_licenses(caps)

    {:ok, gen2} = Authority.regenesis(uri, kind)

    {%{caps: caps}, gen2}
  end

  # Drive `ActionSet.Identity.activate/2` exactly as the pre-ready boot
  # continuation does — inside the principal's CURRENT authority compartment —
  # and return the resulting `:identity` caps.
  defp activate_caps(authority, slice, uri) do
    Authority.with_current(authority, fn ->
      case Ezagent.ActionSet.Identity.activate(slice, %{self_uri: uri}) do
        {:ok, %{}} -> slice.caps
        {:ok, %{}, reconciled} -> reconciled.caps
      end
    end)
  end

  defp has_current_self_license?(caps, uri) do
    Enum.any?(self_licenses(caps), &Authority.verify_against_current(&1, uri, uri))
  end

  defp self_licenses(caps),
    do: Enum.filter(caps, &(Capability.action_of(&1) == :self_license))

  defp insert_store_row(uri, status) do
    Repo.insert!(%Store{
      uri: uri |> Ezagent.URI.instance() |> URI.to_string(),
      identity_status: status,
      caps_json: "[]",
      workspace_uri: uri |> Capability.workspace_of() |> URI.to_string()
    })
  end

  # Point the pre-epoch re-mint's "authority root" at `uri` for the duration.
  defp with_root(uri, fun),
    do: with_app_env(:pre_epoch_remint_root_uri, uri, fun)

  # Force `EntityCaps.Store` reads for `uri` to error (the FIX-2 test seam).
  defp with_forced_store_read_error(uri, fun) do
    key = uri |> Ezagent.URI.instance() |> URI.to_string()
    with_app_env(:p2_forced_read_error_uris, [key], fun)
  end

  defp with_epoch(status, fun) when status in [:active, :inactive],
    do: with_app_env(:identity_cutover_active_override, status == :active, fun)

  defp with_app_env(key, value, fun) do
    previous = Application.get_env(:ezagent_domain_identity, key, :unset)
    Application.put_env(:ezagent_domain_identity, key, value)

    try do
      fun.()
    after
      case previous do
        :unset -> Application.delete_env(:ezagent_domain_identity, key)
        prev -> Application.put_env(:ezagent_domain_identity, key, prev)
      end
    end
  end
end
