defmodule Ezagent.Identity.PreEpochRemint do
  @moduledoc """
  PRE-EPOCH gen-reboot self-license re-mint — the canary boot regression fix
  (deploy run 30456630379), extracted from `ActionSet.Identity.activate/2` so the
  behavior module stays under the oversized-module cap and the security-sensitive
  eligibility predicate lives in one auditable place.

  ## Why a re-mint at all

  The default-SessionTemplate `§3` boot seed dispatches AS the genesis admin. The
  principal gate (`EntityCaps.verified/2`) gen-gates the admin's self-license
  against its CURRENT authority generation; on a REFLOWED prod DB whose admin
  authority was rotated (or that predates the self-license) the persisted license
  is stale/absent → the gate yields `[]` → `:holder_revoked` → boot hard-fails.
  The self-license is minted once at `:created` and never re-minted on `:existed`,
  so a durable principal cannot re-establish currency pre-epoch without a boot
  re-mint — the legacy "durable cap + gen-reboot re-mint" contract this restores.

  ## Why this cannot resurrect a revoked principal (the security core)

  Generation rotation IS a revocation mechanism: `Cap.revoke_all_to/2` and
  `DeleteUser.invalidate_one/2` both advance a principal's generation to cut it
  off (`revoke_all_to` does ONLY a gen-bump — it does NOT downgrade the identity
  store row or set a fence — `kind/server.ex` `:ezagent_revoke_all_to`;
  `delete_user` regenesis + clears the license + CLEARS its own fence). So a
  killed principal's durable footprint (absent/`:active` store row, no fence,
  stale license) is INDISTINGUISHABLE from a legitimate legacy stale-license
  principal. The store row therefore cannot certify *whether* to re-mint — only a
  `:revoked_unprovisioned`/`:tombstoned` row is a positive kill-witness, and
  `revoke_all_to` never produces one.

  The re-mint is therefore gated on *WHO*: the **canonical genesis admin** — the
  root of the authority chain (`Cap.Authority` genesis references it as granter;
  `ensure_admin_user/0` re-ensures its `users` row at EVERY boot; it is the sole
  `§3` boot-seed holder). "Revocation" is undefined for the authority root — the
  system re-bootstraps it unconditionally — so restoring its self-license at boot
  is correct and idempotent. Every OTHER entity principal (regular users/agents,
  and even system-scoped `entity://system/agent/*` role agents, which CAN be
  `revoke_all_to`'d) is EXCLUDED, so a killed principal is never resurrected.

  Store-row-not-revoked + not-fenced are kept as FAIL-CLOSED defense-in-depth: an
  explicitly store-revoked or fenced admin (operator kill / offboarding) is NOT
  auto-healed, and a store/fence READ ERROR blocks the re-mint (never fails open).

  ## Decision table (`principal × store-row × epoch → re-mint`)

      principal        | epoch      | fence | store-row status        | re-mint?
      -----------------|------------|-------|-------------------------|---------
      genesis admin    | :inactive  | clear | active | absent          | YES (heal)
      genesis admin    | :inactive  | clear | revoked_unprovisioned   | NO (fail-closed)
      genesis admin    | :inactive  | clear | tombstoned              | NO (fail-closed)
      genesis admin    | :inactive  | fenced| *                       | NO (fail-closed)
      genesis admin    | :inactive  | *     | READ ERROR              | NO (fail-closed)
      genesis admin    | :active    | *     | *                       | NO (post-epoch)
      genesis admin    | :unknown   | *     | *                       | NO (fail-closed)
      any non-admin    | *          | *     | *                       | NO (not the root)

  ## Concurrency

  The re-mint runs inside a `Repo.transaction` that `lock_current_generation/1`s
  the target authority row (`FOR SHARE`), then verifies the minted license against
  the CURRENT generation — so a `regenesis/2` that commits between the init-time
  authority open and this activate cannot leave us signing under a stale
  generation (a stale mint verifies `false` and is discarded).
  """

  require Logger

  alias Ezagent.Capability
  alias Ezagent.Cap.Authority
  alias Ezagent.Entity.User
  alias Ezagent.EntityCaps.Store
  alias Ezagent.Identity.Cutover
  alias Ezagent.Identity.Offboarding.RevocationFence
  alias EzagentCore.Repo

  @doc """
  Return `state` with a freshly re-minted CURRENT-generation self-license IFF the
  principal is eligible (see the moduledoc decision table); otherwise return
  `state` unchanged. Fully fail-safe — any error leaves the (stale) slice
  untouched and the fail-closed principal gate denies exactly as before.

  Called from `ActionSet.Identity.activate/2` (pre-`ReadyGate`, inside the
  principal's own authority compartment, so `issue_self_license_current` signs
  under the current in-scope authority).
  """
  @spec remint(%{caps: term()}, URI.t()) :: %{caps: term()}
  def remint(%{caps: caps} = state, %URI{} = uri) do
    # CHEAP, DRIFT-FREE pre-gate: only the authority ROOT is ever eligible, and a
    # URI cannot change under us, so skip the transaction entirely for every other
    # principal (the ~100% case). Every DRIFT-SENSITIVE condition (epoch, fence,
    # store, history, no-current-license) is re-read INSIDE the locked transaction.
    if authority_root?(uri) do
      case locked_remint(caps, uri) do
        {:ok, relicensed} -> %{state | caps: relicensed}
        :skip -> state
      end
    else
      state
    end
  rescue
    _ -> state
  catch
    _, _ -> state
  end

  def remint(state, _uri), do: state

  # The un-forgeable structural witness: the canonical genesis admin
  # (`entity://system/user/admin`). No regular principal (nor a system-scoped
  # `entity://system/agent/*` role agent, which CAN be `revoke_all_to`'d) can
  # present this URI — provisioning under `workspace://system` requires admin
  # authority — so a killed principal can never satisfy it. B1-hybrid backs this
  # with STRUCTURAL un-killability: `Cap.revoke_all_to/2`, `DeleteUser`, and
  # `Authority.regenesis/2` all REJECT `admin_uri()`, so a "deliberately-killed
  # admin" is UNREACHABLE — a stale-gen admin is therefore ALWAYS legitimate
  # (reflow / restore), and the ONLY sanctioned rotation
  # (`Ezagent.Identity.AdminKeyRotation`) re-mints atomically (no stale window).
  defp authority_root?(uri) do
    Ezagent.URI.stable_key(uri) == Ezagent.URI.stable_key(root_uri())
  end

  # PROD is HARDCODED to the genesis admin. The `:pre_epoch_remint_root_uri`
  # override — which redefines "the authority root eligible for auto-re-mint", the
  # single most security-sensitive lever here — is compiled IN only for
  # `MIX_ENV=test` (the `@p2_forced_read_error_seam` precedent: provably
  # unreachable in a dev/prod/release build), so the sandboxed regression can
  # exercise the eligible path against a fabricated system principal WITHOUT
  # mutating the VM-global admin, while prod can never point the root at a
  # killable principal.
  @root_override_seam Mix.env() == :test

  if @root_override_seam do
    defp root_uri,
      do: Application.get_env(:ezagent_domain_identity, :pre_epoch_remint_root_uri, User.admin_uri())
  else
    defp root_uri, do: User.admin_uri()
  end

  defp has_current_self_license?(caps, uri) do
    Enum.any?(caps, fn cap ->
      Capability.action_of(cap) == :self_license and
        Authority.verify_against_current(cap, uri, uri)
    end)
  end

  # `RevocationFence.fenced?/1` already fails CLOSED (a read error resolves to
  # `true` = fenced), so `not fenced?` blocks the re-mint on any fence-read error.
  defp fence_clear?(uri), do: not RevocationFence.fenced?(uri)

  # The identity-caps store row is the DURABLE revocation ledger where a positive
  # kill-record exists. A `:revoked_unprovisioned`/`:tombstoned` row → NEVER
  # re-mint. An `:active` row or a genuinely ABSENT row (`{:ok, nil}`) permits it
  # (the admin is the only principal that reaches here). A store READ ERROR →
  # NEVER (fail-closed): a lost/unreadable ledger must not license a re-mint. Also
  # closes the epoch-row-loss case — the ROW check blocks a store-ledgered
  # revocation regardless of epoch.
  defp store_permits_remint?(uri) do
    case Store.status_result(uri) do
      {:ok, status} when status in [:revoked_unprovisioned, :tombstoned] -> false
      {:ok, _active_or_absent} -> true
      :error -> false
    end
  end

  # Fail-CLOSED authority-history read (MAJOR-3): an ABSENT store row is only the
  # legitimate reflow/legacy case for a principal that HAS authority history; a
  # history-read error or a genuine no-history "phantom" must BLOCK the re-mint.
  # `Authority.has_authority_history?/1` fails OPEN (unreadable ⇒ true), so use the
  # error-aware result variant and require an affirmative `{:ok, true}`.
  defp authority_history_present?(uri) do
    Authority.has_authority_history_result?(uri) == {:ok, true}
  end

  # The FULL drift-sensitive eligibility, re-read INSIDE the locked transaction
  # (MAJOR-2): a DEFINITIVE `:inactive` epoch, no current self-license already, the
  # fence clear (fail-closed), the store row not a revocation record (fail-closed),
  # and authority history present (fail-closed). The `authority_root?` identity
  # gate is the cheap drift-free pre-check in `remint/2`.
  defp eligible_under_lock?(caps, uri) do
    Cutover.status() == :inactive and
      not has_current_self_license?(caps, uri) and
      fence_clear?(uri) and
      store_permits_remint?(uri) and
      authority_history_present?(uri)
  end

  # ATOMIC re-mint (MAJOR-2): lock the current authority row FIRST, then re-read
  # the ENTIRE eligibility predicate (epoch/fence/store/history/no-current-license)
  # and mint + re-verify — all under the one lock, so no epoch-activation / fence /
  # store transition can slip between the check and the mint. The mint is current
  # by construction (signed under the locked in-scope authority) and re-verified
  # before commit. The caps_json/store PROJECTION (`persist_user_caps_after_marker`
  # in `activate/2`) rides outside the lock by design: the sole re-mint target is
  # the STRUCTURALLY UN-KILLABLE admin, which cannot be concurrently regenesis'd
  # (only `AdminKeyRotation` advances it, under this same lock), so there is no
  # adversarial drift; the live-slice update is the authoritative outcome and
  # caps_json is a best-effort projection that self-heals on the next boot.
  defp locked_remint(caps, uri) do
    Repo.transaction(fn ->
      :ok = Authority.lock_current_generation(uri)

      if eligible_under_lock?(caps, uri) do
        without_stale = drop_self_licenses(caps)

        with {:ok, relicensed} <- Ezagent.ActionSet.Identity.mint_self_license(without_stale, uri),
             true <- has_current_self_license?(relicensed, uri) do
          relicensed
        else
          _ -> Repo.rollback(:remint_not_current)
        end
      else
        Repo.rollback(:not_eligible)
      end
    end)
    |> case do
      {:ok, relicensed} ->
        {:ok, relicensed}

      {:error, reason} ->
        Logger.debug("PreEpochRemint: re-mint skipped for #{URI.to_string(uri)}: #{inspect(reason)}")

        :skip
    end
  end

  defp drop_self_licenses(caps) do
    caps
    |> Enum.reject(&(Capability.action_of(&1) == :self_license))
    |> MapSet.new()
  end
end
