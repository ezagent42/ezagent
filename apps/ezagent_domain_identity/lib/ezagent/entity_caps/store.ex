defmodule Ezagent.EntityCaps.Store do
  @moduledoc """
  #189 / #185 PR-1 (identity-plane cutover step 1, ADDITIVE) — the unified
  per-entity identity-caps store.

  This is the generalization of `Ezagent.EntityCaps.UserStore`
  (`users.caps_json`) to EVERY entity URI: one row per canonical entity URI
  holds

    * `caps_json` — the COMPLETE held-cap set (serialized
      `[Ezagent.Capability.to_map/1]` maps), including the self-license;
    * `identity_status` — `active | revoked_unprovisioned | tombstoned`
      (monotone: `active → revoked_unprovisioned`, `* → tombstoned`; leaving
      a non-active state requires an authenticated re-provision);
    * `provisioning_receipt` — the authenticated proof
      (`Ezagent.Identity.ProvisioningReceipt`) that the current `active`
      state was created by genuine provision/re-provision, not a spawn race;
    * `workspace_uri` — the entity URI's workspace (per-tenant gate).

  `kind_cap_authorities` is unchanged (signing keys + generation). This store
  holds caps + status + receipt.

  ## PR-1 contract (codex review F1): WRITE-SHADOW ONLY

  In PR-1 this store is a **write-shadow**, never an authoritative read
  source:

    * Dual-WRITE: every cap mutation writes BOTH the legacy store
      (`users.caps_json` for users / the snapshot `:identity` slice for
      other durable entities) AND this store. The write points are
      `UserStore.update/2` (mirror runs AFTER the `caps_json` commit, OUTSIDE
      its transaction — a shadow failure can never roll it back), the
      `Kind.Snapshot.save_now`
      chokepoint (init / post-init / commit / Writer flush / terminate),
      the `Kind.Server` commit hook (covers `:not_durable` commits), and
      `SnapshotStore.write/delete` — so this store mirrors each entity's
      LEGACY authoritative source as closely as a shadow can.
    * Reads: NO production read path consults this store in PR-1. Legacy
      reads (`users.caps_json` / snapshot `:identity`) stay authoritative;
      a divergent or missing shadow row can therefore NEVER change an
      authorization outcome. The `fetch_durable_*` read APIs below exist
      for the atomic cutover PR (which flips reads to the store only after
      verifying parity fleet-wide) and are exercised by unit tests only.
    * Mirror writes are best-effort but NEVER silent: every failure is
      logged at `:error` (the legacy write still succeeds — shadow
      divergence is observable and the migration PR reconciles).
    * Ephemeral/external-persistence Kinds are NOT mirrored in PR-1 (their
      identity durability arrives with the atomic cutover); users are
      mirrored via `users.caps_json` writes only.

  The provisioning API (`provision/4`, `reprovision/4`,
  `revoke_provisioning/1`, `tombstone/1`) is additive in PR-1; nothing in
  the runtime calls it yet.
  """

  use Ecto.Schema

  import Ecto.Query

  require Logger

  alias Ezagent.Capability
  alias Ezagent.Identity.ProvisioningReceipt
  alias EzagentCore.Repo

  @type status :: :active | :revoked_unprovisioned | :tombstoned

  @primary_key {:uri, :string, autogenerate: false}
  schema "identity_caps" do
    field(:caps_json, :string)
    field(:identity_status, :string, default: "active")
    field(:provisioning_receipt, :string)
    field(:workspace_uri, :string)

    timestamps(type: :utc_datetime_usec)
  end

  # ====================================================================
  # Reads (cutover-facing — NOT wired into any authoritative read in PR-1)
  # ====================================================================

  @doc "Fetch the raw row for `uri` (`nil` when absent)."
  @spec fetch(URI.t() | String.t()) :: %__MODULE__{} | nil
  def fetch(uri) do
    Repo.get(__MODULE__, key(uri))
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc "Whether a store row exists for `uri`."
  @spec has_row?(URI.t() | String.t()) :: boolean()
  def has_row?(uri), do: not is_nil(fetch(uri))

  @doc """
  The addendum §4 existence signal for the CapBAC read classifier: a store
  row proves the URI is a KNOWN entity even when no durable snapshot row
  exists. USER URIs are excluded — their existence source remains `users` /
  snapshots (a `users.caps_json` mirror write must not reclassify a
  snapshot-less user from `:absent` to transient). Cutover-facing: NOT
  consulted by the read classifier in PR-1.
  """
  @spec existence_signal?(URI.t() | String.t()) :: boolean()
  def existence_signal?(uri), do: not user_uri?(uri) and has_row?(uri)

  @doc """
  #189 PR-3 cutover — the FAIL-CLOSED durable ever-created signal for
  `Kind.Server.create_freshness/2`.

  For an `:ephemeral` principal `fresh_create?` (the snapshot `ever_created`
  marker) is ALWAYS true (an ephemeral Kind writes no snapshot marker), so THIS
  signal is the SOLE determinant of `:created` vs `:existed` at cutover — and a
  wrong `:created` on a restart re-mints the self-license AND bumps the authority
  generation (`open(:created)`), i.e. RESURRECTS a revoked principal. So it must
  never fail OPEN. It returns `true` (ever-created ⇒ `:existed`, no re-mint)
  UNLESS the read SUCCEEDS and finds no row (⇒ genuine first creation). A read
  ERROR resolves to `true`, mirroring `Lifecycle.marker_lookup`'s contract ("a
  marker-store failure must never be interpreted as permission to run the
  one-time create path again"). USER URIs return `false` — their creation-fact is
  the snapshot marker / `users` row, not this store (`existence_signal?`
  precedent).
  """
  @spec ever_created_signal?(URI.t() | String.t()) :: boolean()
  def ever_created_signal?(uri) do
    cond do
      # EPOCH-GATED (FIX 5): before the cutover epoch (a DEFINITIVE `:inactive`)
      # the store is NOT consulted for the ephemeral freshness decision. `false`
      # ⇒ the caller keeps the PR-1 legacy freshness semantics (the snapshot
      # `ever_created` marker alone; for an ephemeral Kind that is
      # unconditionally `:created`). The store becomes the ever-created authority
      # ONLY post-epoch.
      Ezagent.Identity.Cutover.status() == :inactive ->
        false

      user_uri?(uri) ->
        false

      # #189 PR-3 FINAL — an UNREADABLE epoch (`:unknown`) FAILS CLOSED to
      # `true` (⇒ `:existed`, NO re-mint), mirroring the `:error` read-result
      # contract below: on a post-cutover node with an unreadable epoch, a wrong
      # `:created` would re-mint the self-license AND bump the authority
      # generation (resurrecting a revoked ephemeral principal). Deny re-mint
      # until the epoch reads definitively.
      Ezagent.Identity.Cutover.status() == :unknown ->
        true

      true ->
        case fetch_result(uri) do
          # A SUCCESSFUL absent read is NOT sufficient for `:created` when the
          # URI already has AUTHORITY HISTORY (`kind_cap_authorities` rows —
          # preserved across `regenesis`, which retires+inserts, never deletes):
          # that combination is a previously-created principal whose store row
          # was cleared/never-mirrored, so it reports ever-created (⇒ `:existed`,
          # no re-mint) — the FIX 3 anti-resurrection property. Only a genuine
          # first creation (no row AND no authority history) reports `false`.
          {:ok, nil} -> Ezagent.Cap.Authority.has_authority_history?(uri_struct(uri))
          {:ok, %__MODULE__{}} -> true
          :error -> true
        end
    end
  end

  # TEST-ONLY forced-read-error seam (the `@p1_forced_shadow_failure_seam`
  # precedent): compiled IN only for `MIX_ENV=test`, provably unreachable in a
  # dev/prod/release build. Consulted ONLY when the app env
  # `:ezagent_domain_identity, :p2_forced_read_error_uris` is set (a list of URI
  # strings) — never set outside the FIX 2 read-error regression. It lets the
  # regression force `fetch_result/1` to `:error` for a target so
  # `fetch_durable_caps/1` returns `{:error, _}` and the read-error-DENIES path
  # is exercised deterministically (a real DB error is not reproducible in the
  # sandbox).
  @p2_forced_read_error_seam Mix.env() == :test

  # Like `fetch/1` but DISTINGUISHES a successful "no row" (`{:ok, nil}`) from a
  # read error (`:error`) — `fetch/1` collapses both to `nil`, which would make
  # `ever_created_signal?` fail OPEN and `fetch_durable_caps` fall back to legacy
  # on error (FIX 2). Do not route those through `fetch/1`.
  if @p2_forced_read_error_seam do
    defp fetch_result(uri) do
      case Application.get_env(:ezagent_domain_identity, :p2_forced_read_error_uris) do
        nil -> real_fetch_result(uri)
        uris -> if key(uri) in uris, do: :error, else: real_fetch_result(uri)
      end
    end
  else
    defp fetch_result(uri), do: real_fetch_result(uri)
  end

  defp real_fetch_result(uri) do
    {:ok, Repo.get(__MODULE__, key(uri))}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  @doc """
  The URI strings of every `active` store row — the fleet-parity barrier's
  backward (store → legacy) enumeration (#189 PR-2). URI-only projection: it
  never decodes `caps_json`, so it is not a raw-cap accessor.
  """
  @spec active_uris() :: [String.t()]
  def active_uris do
    from(row in __MODULE__, where: row.identity_status == "active", select: row.uri)
    |> Repo.all()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc "The identity lifecycle status for `uri`, or `nil` when no row exists."
  @spec status(URI.t() | String.t()) :: status() | nil
  def status(uri) do
    case fetch(uri) do
      nil -> nil
      %{identity_status: status} -> decode_status(status)
    end
  end

  @doc """
  The identity lifecycle status for `uri` as a FAIL-CLOSED result — distinguishing
  a store read ERROR (`:error`) from a genuinely absent row (`{:ok, nil}`) via the
  `fetch_result/1` precedent. `status/1` collapses a read error to `nil` (fails
  OPEN, indistinguishable from absent). Callers that must treat an unreadable
  revocation ledger as "deny" (e.g. `Ezagent.Identity.PreEpochRemint`'s eligibility
  gate) use THIS, never `status/1`.
  """
  @spec status_result(URI.t() | String.t()) :: {:ok, status() | nil} | :error
  def status_result(uri) do
    case fetch_result(uri) do
      {:ok, nil} -> {:ok, nil}
      {:ok, %__MODULE__{identity_status: status}} -> {:ok, decode_status(status)}
      :error -> :error
    end
  end

  @doc """
  The complete held-cap set for `uri` — ONLY when the row is `active`.

  A row in `revoked_unprovisioned` / `tombstoned` state yields `[]` (the URI
  is inert until re-provisioned), NEVER a fallback: a present non-active row
  is authoritative about the holder being empty. Absent row → `[]` as well;
  cutover dual-read fallback uses `fetch_durable_caps/1`.
  """
  @spec load(URI.t() | String.t()) :: [Capability.t()]
  def load(uri) do
    case fetch(uri) do
      %{identity_status: "active", caps_json: caps_json} -> decode_caps(caps_json)
      _ -> []
    end
  end

  @doc """
  Cutover-facing dual-read entry point for `load_persisted/1` (the
  `Ezagent.EntityCaps` persisted-cap read). Three DISTINCT outcomes (FIX 2 —
  read failure is not absence):

    * `{:ok, caps}` — a PRESENT row: the complete cap set for an `active` row,
      or `[]` for a `revoked_unprovisioned` / `tombstoned` row (authoritative-
      empty, NEVER a fallback — a present non-active row is the source of truth
      about the holder being inert);
    * `:absent` — a SUCCESSFUL read that found NO row (the caller may fall back
      to the legacy store — `users.caps_json` / snapshot `:identity`);
    * `{:error, reason}` — the store read itself FAILED. The caller MUST DENY
      (`[]`), NEVER fall back: a DB error must not be interpreted as "no row"
      and let a legacy self-license authorize a principal the authoritative
      store would deny (e.g. a store-only provisioning revocation).

  Routes through `fetch_result/1` (which distinguishes `{:ok, nil}` from
  `:error`), NOT `fetch/1` (which collapses both to `nil`).
  """
  @spec fetch_durable_caps(URI.t() | String.t()) ::
          {:ok, [Capability.t()]} | :absent | {:error, term()}
  def fetch_durable_caps(uri) do
    case fetch_result(uri) do
      {:ok, nil} -> :absent
      {:ok, %__MODULE__{identity_status: "active", caps_json: caps_json}} -> {:ok, decode_caps(caps_json)}
      {:ok, %__MODULE__{}} -> {:ok, []}
      :error -> {:error, :store_read_failed}
    end
  end

  @doc """
  Cutover-facing dual-read entry point for the `Kind.read_durable/3`
  `:identity` projection (actor seam, config-injected): the synthesized
  `:identity` slice `%{caps: MapSet.t()}` plus `read_durable`-shaped meta,
  or `:fallback`. NOT consulted by `Kind.read_durable` in PR-1.
  """
  @spec fetch_durable_identity(URI.t() | String.t()) ::
          {:ok, %{caps: MapSet.t(Capability.t())}, %{version: 0, updated_at: DateTime.t() | nil}}
          | :fallback
  def fetch_durable_identity(uri) do
    case fetch(uri) do
      nil ->
        :fallback

      %{identity_status: status, caps_json: caps_json, updated_at: updated_at} ->
        caps =
          if status == "active",
            do: caps_json |> decode_caps() |> MapSet.new(),
            else: MapSet.new()

        {:ok, %{caps: caps}, %{version: 0, updated_at: updated_at}}
    end
  end

  @doc """
  Batch variant of `fetch_durable_identity/1` for `Kind.read_durable_many/3`:
  one query, returns only the URIs that have a store row. Cutover-facing.
  """
  @spec fetch_durable_identities([URI.t() | String.t()]) :: %{
          optional(String.t()) =>
            {:ok, %{caps: MapSet.t(Capability.t())},
             %{version: 0, updated_at: DateTime.t() | nil}}
        }
  def fetch_durable_identities(uris) when is_list(uris) do
    keys = Enum.map(uris, &key/1)

    from(row in __MODULE__, where: row.uri in ^keys)
    |> Repo.all()
    |> Map.new(fn row ->
      caps =
        if row.identity_status == "active",
          do: row.caps_json |> decode_caps() |> MapSet.new(),
          else: MapSet.new()

      {row.uri, {:ok, %{caps: caps}, %{version: 0, updated_at: row.updated_at}}}
    end)
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  # ====================================================================
  # Dual-write mirror (PR-1 shadow writes — preserve status + receipt)
  # ====================================================================

  # TEST-ONLY forced-failure seam (the `Kind.Snapshot`
  # `@p2_5c_commit_failure_seam_enabled` precedent): compiled IN only for
  # `MIX_ENV=test`, so in a dev/prod/release build `persist/2` is a direct
  # `do_persist/2` call and the seam is provably unreachable. Consulted ONLY
  # when the app env `:ezagent_domain_identity,
  # :p1_forced_shadow_failure_uris` is set (a list of URI strings) — never
  # set outside the one regression test — so this is a pure no-op off that
  # test path. It lets the UserStore write-shadow regression
  # deterministically fail the SHADOW write while the authoritative
  # `caps_json` write succeeds, proving the shadow failure can neither roll
  # back nor silently pass (codex round-3).
  @p1_forced_shadow_failure_seam Mix.env() == :test

  # TEST-ONLY interleave seam (same `Mix.env() == :test` precedent): lets a
  # regression fire an `Authority.regenesis/2` DURING an active-transition,
  # AFTER the identity row is locked but BEFORE the self-license is verified,
  # to prove the verify runs INSIDE the transaction (codex impl-review finding
  # 1, acceptance (c)). Pre-fix, `licensed?` was computed before the
  # transaction, so a mid-transition regenesis could not affect it and the row
  # would stay `active` (resurrection); with the verify inside the txn it sees
  # the bumped generation and lands `revoked_unprovisioned`. Consulted ONLY when
  # the app env `:p2_verify_race_hook` is set (a 1-arity fun) — never set outside
  # the one regression — so it is a pure no-op off that test path, and provably
  # unreachable in a dev/prod/release build.
  @p2_verify_race_seam Mix.env() == :test

  @doc """
  Upsert the complete cap set for `uri`, computing `identity_status` STRUCTURALLY
  from the mirrored caps — the #189 PR-2 write-boundary resurrection guard
  (codex spec-review F1: "securing only the backfill does not secure the
  store").

  The invariant this writer enforces: **an `active` row's caps carry a
  current-valid `:self_license`** (verified fresh against the URI's current
  authority generation via `Ezagent.Cap.Authority.verify_against_current/3` —
  mere presence in the caps is not enough; a revocation bumps the generation
  and leaves stale licenses behind). So no shadow / mirror write can ever
  create OR keep an `active` row for a license-invalid principal:

    * fresh row — `active` iff the caps carry a current-valid self-license,
      else `revoked_unprovisioned` (the URI is inert until an authenticated
      re-provision; NEVER left silently `active`);
    * existing `active` row — mirror the caps, but DOWNGRADE to
      `revoked_unprovisioned` when the mirrored set no longer carries a
      current-valid self-license (a stale legacy write after a revocation);
    * existing `revoked_unprovisioned` — mirror the caps for observability but
      NEVER upgrade the status (only `reprovision/4` leaves that state);
    * existing `tombstoned` — preserved untouched (a shadow write never
      overwrites a tombstone).

  This is still a mirror op: it does NOT consume a receipt and does NOT change
  a `revoked`/`tombstoned` lifecycle back to `active`. An `active` row created
  here carries `provisioning_receipt: nil` — legitimate under the store's
  TWO-proof model (codex F5): an `active` row is proven either by a consumed
  `ProvisioningReceipt` OR by a current-valid self-license in its caps
  ("grandfathered" activation). The write-boundary guard enforces the latter.
  """
  @spec persist(URI.t() | String.t(), [Capability.t()] | MapSet.t(Capability.t())) ::
          :ok | {:error, term()}
  if @p1_forced_shadow_failure_seam do
    def persist(uri, caps) when is_list(caps) or is_struct(caps, MapSet) do
      case Application.get_env(:ezagent_domain_identity, :p1_forced_shadow_failure_uris) do
        nil ->
          do_persist(uri, caps)

        uris ->
          if key(uri) in uris do
            # Structural probe (codex round-4): record whether the shadow write
            # is executing INSIDE a DB transaction. F2 moved the user mirror
            # OUTSIDE the authoritative `caps_json` transaction, so this MUST be
            # `false`; if the mirror were moved back inside `Repo.transaction/1`
            # it flips to `true` and the regression's structural assertion goes
            # red. A plain `{:error}` return (below) is caught + logged by
            # `UserStore.mirror_identity_caps/2` and never poisons the enclosing
            # txn, so the outcome assertions alone cannot distinguish the pre-F2
            # layout — THIS probe is what actually proves F2.
            Process.put(:p1_forced_shadow_failure_in_transaction?, Repo.in_transaction?())
            {:error, {:p1_forced_shadow_failure, key(uri)}}
          else
            do_persist(uri, caps)
          end
      end
    end
  else
    def persist(uri, caps) when is_list(caps) or is_struct(caps, MapSet) do
      do_persist(uri, caps)
    end
  end

  defp do_persist(uri, caps) do
    uri_key = key(uri)
    workspace = workspace_key(uri)
    caps_list = Enum.to_list(caps)
    encoded = encode_caps(caps_list)

    case Repo.transaction(fn -> persist_locked(uri, uri_key, workspace, encoded, caps_list) end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The self-license verification runs INSIDE this transaction, under the
  # authority-row lock (`licensed_under_lock?/2`), so a concurrent
  # `Authority.regenesis/2` cannot rotate the generation between the verify and
  # this write (codex impl-review finding 1 — the verify/write race). A row is
  # never `active` unless a current-valid self-license holds at write time.
  defp persist_locked(uri, uri_key, workspace, encoded, caps_list) do
    with :ok <- ensure_row(uri_key, workspace),
         row when not is_nil(row) <- lock_row(uri_key),
         licensed? <- licensed_under_lock?(uri, caps_list),
         changes <- persist_changes(row, encoded, licensed?),
         {:ok, _row} <- row |> Ecto.Changeset.change(changes) |> Repo.update() do
      :ok
    else
      nil -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A `tombstoned` row is terminal — a mirror write never overwrites it.
  defp persist_changes(%{identity_status: "tombstoned"}, _encoded, _licensed?),
    do: [updated_at: now_usec()]

  # A `revoked_unprovisioned` row is NEVER upgraded by a shadow write (only an
  # authenticated `reprovision/4` restores it). Mirror the caps for
  # observability; leave status + receipt untouched.
  defp persist_changes(%{identity_status: "revoked_unprovisioned"}, encoded, _licensed?),
    do: [caps_json: encoded, updated_at: now_usec()]

  # An `active` row (including the just-inserted fresh default): mirror the
  # caps, but the status is `active` ONLY while a current-valid self-license is
  # present — otherwise DOWNGRADE to `revoked_unprovisioned` (fresh
  # license-missing entity, or a stale post-revocation mirror).
  defp persist_changes(%{identity_status: "active"}, encoded, licensed?) do
    status = if licensed?, do: "active", else: "revoked_unprovisioned"
    [caps_json: encoded, identity_status: status, updated_at: now_usec()]
  end

  @doc """
  Row-locked transform of the complete cap set (mirrors
  `UserStore.update/2` semantics, upserting): the row is created when
  absent, then locked `FOR UPDATE`, decoded, transformed, and re-encoded.

  The resulting caps route through the SAME resurrection guard as `persist/2`
  (codex impl-review finding 1 — `update/2` was a bypass: it wrote caps and left
  the fresh row on the schema's `"active"` default with no self-license check).
  The transformed set decides the status structurally via `persist_changes/3`:
  an absent/`active` row whose new caps carry no current-valid self-license lands
  `revoked_unprovisioned`, never silently `active`; a `revoked_unprovisioned` /
  `tombstoned` row is never upgraded. The `fun`'s own `{:error, reason}` is
  propagated verbatim (the transaction rolls back, leaving prior state intact).
  """
  @spec update(URI.t() | String.t(), ([Capability.t()] ->
                                        {:ok, [Capability.t()] | MapSet.t(Capability.t())}
                                        | {:error, term()})) ::
          :ok | {:error, term()}
  def update(uri, fun) when is_function(fun, 1) do
    case Repo.transaction(fn -> update_locked(uri, key(uri), workspace_key(uri), fun) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_locked(uri, uri_key, workspace, fun) do
    with :ok <- ensure_row(uri_key, workspace),
         row when not is_nil(row) <- lock_row(uri_key),
         {:ok, caps} <- fun.(decode_caps(row.caps_json)) do
      caps_list = Enum.to_list(caps)
      licensed? = licensed_under_lock?(uri, caps_list)
      changes = persist_changes(row, encode_caps(caps_list), licensed?)

      case row |> Ecto.Changeset.change(changes) |> Repo.update() do
        {:ok, _row} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      nil -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_row(uri_key, workspace) do
    %__MODULE__{}
    |> Ecto.Changeset.change(uri: uri_key, workspace_uri: workspace)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :uri)
    |> case do
      {:ok, _row} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp lock_row(uri_key) do
    Repo.one(from(r in __MODULE__, where: r.uri == ^uri_key, lock: "FOR UPDATE"))
  end

  # ====================================================================
  # Actor seams (config-injected; EPOCH-AWARE — pre-epoch a best-effort shadow
  # that never fails the committing dispatch; post-epoch AUTHORITATIVE, so a
  # failed identity write fails the caller — FIX 1. Every failure is logged.)
  # ====================================================================

  @doc """
  Dual-write hook for the snapshot write paths (`Kind.Snapshot.save_now`,
  the `Kind.Server` commit hook, and direct `SnapshotStore.write`).

  `slice` is the raw `:identity` slice (any shape: Lifecycle two-container,
  persisted single-key `%{state: _}`, or legacy flat). Skipped (returns
  `:ok` without writing) when:

    * `uri` is a USER — user rows mirror `users.caps_json` via
      `UserStore.update/2` instead (the legacy authoritative user source);
    * `kind_module` is `:ephemeral`/`:external` persistence — those Kinds
      are deliberately NOT mirrored (`nil` kind_module, the direct
      `SnapshotStore.write/3` path, always mirrors: durable writers only);
    * the slice carries no caps set.

  ## Epoch-aware outcome (FIX 1 + #189 PR-3 FINAL ITEM 1)

    * **Pre-epoch** (`Cutover.status/0` `:inactive`) / skipped / `:unknown`
      no-commit: a best-effort shadow. On success returns a bare `:ok`; the
      snapshot remains authoritative, so the actor writer treats a subsequent
      snapshot failure as a REAL failure. Any store failure is logged and
      SWALLOWED (`:ok`) pre-epoch so it never fails the legacy-authoritative
      commit (post-epoch / `:unknown` it PROPAGATES — see `swallow_pre_epoch/1`).
    * **Post-epoch** (`:active`) SUCCESS: returns `{:ok, :authoritative}` — the
      mutation is COMMITTED the instant the store row lands. The actor writer
      (`save_now/4` / `SnapshotStore.write/3`, both Store-FIRST) uses this to
      keep the reported outcome consistent with the authoritative plane: a
      subsequent snapshot PROJECTION failure must NOT be reported as a mutation
      failure (the self-authz read consults the persisted store, so reporting
      failure while the store holds the mutation is the ITEM-1 divergence).
    * **Post-epoch FAILURE**: returns `{:error, reason}` so the caller aborts the
      snapshot commit — a cap mutation must not report success, and a revoke must
      not leave a stale cap in the authoritative store.
  """
  @spec sync_committed_identity(URI.t() | String.t(), module() | nil, term()) ::
          :ok | {:ok, :authoritative} | {:error, term()}
  def sync_committed_identity(uri, kind_module, slice) do
    with false <- user_uri?(uri),
         false <- skip_kind?(kind_module),
         %MapSet{} = caps <- slice_caps(slice) do
      # #189 PR-3 FINAL (ITEM 2) — resolve `Cutover.status/0` BEFORE the Store
      # write. An UNREADABLE epoch (`:unknown`) must REJECT a durable non-user
      # mutation, SYMMETRIC with the user path (`UserStore.update/2`): persisting
      # under an epoch we cannot read would advance the authoritative Store row
      # (and, via the caller, live state) under semantics a later DEFINITIVE read
      # might contradict. Fail-closed with an explicit reason and write NEITHER
      # the Store nor (because the caller aborts on `{:error, _}`) the snapshot.
      case Ezagent.Identity.Cutover.status() do
        :unknown ->
          Logger.error(
            "EntityCaps.Store: identity write REFUSED for #{inspect(uri)} — " <>
              "identity epoch unreadable (:unknown)"
          )

          {:error, :identity_epoch_unreadable}

        _status ->
          case persist(uri, caps) do
            :ok ->
              committed_signal()

            {:error, reason} ->
              Logger.error(
                "EntityCaps.Store: identity write FAILED for #{inspect(uri)} " <>
                  "(reason=#{inspect(reason)})"
              )

              swallow_pre_epoch({:error, reason})
          end
      end
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.error(
        "EntityCaps.Store: identity write RAISED for #{inspect(uri)}: " <>
          Exception.message(e)
      )

      swallow_pre_epoch({:error, {:raised, Exception.message(e)}})
  catch
    kind, reason ->
      Logger.error(
        "EntityCaps.Store: identity write FAILED for #{inspect(uri)}: " <>
          "#{kind} #{inspect(reason)}"
      )

      swallow_pre_epoch({:error, {kind, reason}})
  end

  # Pre-epoch (a DEFINITIVE `:inactive`) the store is a best-effort shadow:
  # swallow the failure to `:ok` so a shadow error never fails the
  # legacy-authoritative commit. Post-epoch (`:active`) the store is
  # authoritative: propagate the `{:error, _}` so the caller aborts. #189 PR-3
  # FINAL — an UNREADABLE epoch (`:unknown`) also PROPAGATES the error
  # (fail-closed): we cannot prove the store is a mere shadow, so a failed write
  # must not be silently swallowed.
  defp swallow_pre_epoch(error) do
    case Ezagent.Identity.Cutover.status() do
      :inactive -> :ok
      _ -> error
    end
  end

  # #189 PR-3 FINAL (ITEM 1) — the success signal `sync_committed_identity/3`
  # hands back to the actor-layer snapshot writer. POST-epoch (`:active`) the
  # store row IS the committed mutation, so `{:ok, :authoritative}` tells the
  # writer "already committed authoritatively — a snapshot projection failure
  # must not be reported as a mutation failure". Pre-epoch (`:inactive`) or an
  # unreadable epoch (`:unknown`) the store is NOT the authority for this write,
  # so a bare `:ok` preserves the snapshot-authoritative semantics (a snapshot
  # failure IS a real failure). The actor cannot ask the epoch itself (it lives
  # below the domain), so the authoritative-ness must flow back through here.
  defp committed_signal do
    case Ezagent.Identity.Cutover.status() do
      :active -> {:ok, :authoritative}
      _ -> :ok
    end
  end

  @doc """
  #189 PR-3 FINAL (ITEM 1) — the cold-load reconcile of the durable Store INTO a
  rehydrated live `:identity` slice, run by the actor BEFORE its initial
  `save_now` mirror-back.

  The "Store-committed ⇒ committed" projection contract (`committed_signal/0` +
  `Kind.Snapshot.commit_snapshot`) lets a post-epoch cap mutation report success
  the instant the authoritative Store row lands — even if the SNAPSHOT projection
  then fails, leaving a STALE snapshot on disk. On a cold restart BEFORE another
  successful write, the Kind loads that stale snapshot and unconditionally mirrors
  it back through `persist/2` (`save_now`), which would OVERWRITE the committed
  authoritative mutation — rolling back a grant, or RESURRECTING a revoked cap —
  and the live slice cross-Kind authorization reads (the principal-axis cap-load
  path) would be stale too.

  This closes that hole. On a COLD reload (`:existed`) of a durable, NON-user
  identity principal POST-epoch, when a durable Store row EXISTS, REPLACE the
  rehydrated slice's caps with the Store's authoritative set (a REPLACE, never a
  union — the Store is the source of truth for the committed mutation). The actor
  applies the result to BOTH the live slice and the about-to-run initial
  `save_now`, so the mirror-back writes the correct set and the live slice is
  correct. `verified/2` stays the read gate — a stale-generation Store license
  still loads EMPTY on read — so this never resurrects a gen-revoked holder, and
  the mirror-back's own `persist/2` license guard re-decides `active`-ness.

  Returns `{:replace, reconciled_slice}` (the caller swaps the `:identity` slice)
  or `:keep` (do nothing) — the latter pre-epoch or on an unreadable epoch (don't
  disturb pre-epoch semantics; an `:unknown` epoch cannot leak a stale persist
  because the mirror-back's own `persist/2` is epoch-gated and REJECTS on
  `:unknown`), for a user URI (users reconcile `users.caps_json` via
  `Identity.activate/2`), on a fresh `:created` boot (the minted slice is
  authoritative — there is no prior committed mutation to reconcile), when no
  Store row exists (`:absent` — first creation / un-backfilled), or for a slice
  carrying no caps.

  A Store READ ERROR returns `{:error, {:identity_reconcile_unreadable, _}}` —
  the caller must REFUSE the boot (fail-closed). It must NOT proceed with the
  stale slice: the read path can fail (e.g. an undecodable row) while
  `persist/2` still succeeds, so proceeding would deterministically let the
  stale snapshot overwrite the authoritative Store — exactly the hole this
  reconcile closes.
  """
  @spec reconcile_cold_load_identity(URI.t() | String.t(), atom(), term()) ::
          {:replace, term()} | :keep | {:error, {:identity_reconcile_unreadable, term()}}
  def reconcile_cold_load_identity(uri, create_freshness, identity_slice) do
    with :existed <- create_freshness,
         :active <- Ezagent.Identity.Cutover.status(),
         false <- user_uri?(uri),
         %MapSet{} <- slice_caps(identity_slice) do
      case fetch_durable_caps(uri) do
        {:ok, store_caps} ->
          {:replace, put_slice_caps(identity_slice, MapSet.new(store_caps))}

        :absent ->
          :keep

        {:error, reason} ->
          {:error, {:identity_reconcile_unreadable, reason}}
      end
    else
      _ -> :keep
    end
  end

  # Replace the caps set inside an `:identity` slice, PRESERVING its container
  # shape (the exact shapes `slice_caps/1` reads): Lifecycle two-container
  # `%{state: _, transients: _}`, persisted single-key `%{state: _}`, or legacy
  # flat `%{caps: _}`. Any other shape passes through untouched.
  defp put_slice_caps(%{state: state, transients: transients}, caps) when is_map(state),
    do: %{state: Map.put(state, :caps, caps), transients: transients}

  defp put_slice_caps(%{state: state} = slice, caps)
       when is_map(state) and map_size(slice) == 1,
       do: %{state: Map.put(state, :caps, caps)}

  defp put_slice_caps(%{caps: _} = slice, caps), do: Map.put(slice, :caps, caps)

  defp put_slice_caps(other, _caps), do: other

  @doc """
  Dual-write hook for `SnapshotStore.delete/1`: the legacy durable copy is
  gone, so the shadow row is deleted too — EXCEPT a NON-ACTIVE row
  (`revoked_unprovisioned` / `tombstoned`), which is PRESERVED as durable
  creation/revocation evidence (#189 PR-3 FIX 3; extends the PR-2 tombstone
  monotonicity — codex spec-review F5 — to `revoked_unprovisioned`).

  Both a `tombstoned` AND a `revoked_unprovisioned` row are durable records that
  this URI was CREATED (and, for the latter, revoked). Deleting either on a
  routine snapshot clear would erase the creation evidence: a later restart
  would then find no store row AND — if authority history were also absent —
  look like a genuine creation and RESURRECT the principal. Only an `active` row
  is cleared here (the live-principal legacy destroy semantics are unchanged);
  the anti-resurrection creation evidence is never deleted.
  """
  @spec identity_snapshot_cleared(URI.t() | String.t()) :: :ok | {:error, term()}
  def identity_snapshot_cleared(uri) do
    from(row in __MODULE__,
      where: row.uri == ^key(uri) and row.identity_status == "active"
    )
    |> Repo.delete_all()

    :ok
  rescue
    e ->
      Logger.error(
        "EntityCaps.Store: identity delete FAILED for #{inspect(uri)}: " <>
          Exception.message(e)
      )

      # Epoch-aware (FIX 1): pre-epoch a best-effort shadow (swallow); post-epoch
      # authoritative — a failed clear propagates so the destroy caller sees it.
      swallow_pre_epoch({:error, {:raised, Exception.message(e)}})
  catch
    kind, reason ->
      Logger.error(
        "EntityCaps.Store: identity delete FAILED for #{inspect(uri)}: " <>
          "#{kind} #{inspect(reason)}"
      )

      swallow_pre_epoch({:error, {kind, reason}})
  end

  @doc """
  #189 PR-3 cutover — write the DURABLE identity for an `:ephemeral` principal
  on GENUINE creation (Axis B: "ephemeral is a property of the slice, identity is
  durable").

  An ephemeral Kind's slice is never snapshot-persisted, so the self-license
  minted at `:created` reaches no durable store via the ordinary snapshot
  dual-write (`sync_committed_identity/3` deliberately skips ephemeral). This is
  the explicit, fail-closed boot-path write that makes the ephemeral principal's
  self-license durable so its restart re-reads it (and `principal_current?`
  passes on cold self-dispatch).

  Called from `Kind.Server.persist_initial_snapshot/3` (the pre-ready fail-closed
  seam, symmetric with the durable Kind's atomic initial-snapshot commit) on
  EVERY init for an ephemeral principal — but it is STRUCTURALLY gated to write
  ONLY when the slice carries a CURRENT-valid self-license, which is true ONLY on
  a genuine `:created` mint. On an `:existed` restart the freshly-built ephemeral
  slice carries no self-license, so this is a no-op — it never overwrites (and
  never downgrades) the durable row a genuine creation established. That gate is
  the anti-resurrection property: a revoked/tombstoned principal that restarts
  reports `:existed`, mints nothing, and reaches here with no license → no write.

  `slice` is the `:identity` sub-slice (`slice_state[:identity]`), any shape.
  Returns `:ok` (wrote, or nothing to write) or `{:error, reason}` (the durable
  write failed) so the boot path can `{:stop, ...}` — a self-license that cannot
  be made durable at creation must fail the spawn, not silently create a
  principal that can't self-authorize after restart.
  """
  @spec provision_created_identity(URI.t() | String.t(), term()) :: :ok | {:error, term()}
  def provision_created_identity(uri, slice) do
    case slice_caps(slice) do
      %MapSet{} = caps ->
        caps_list = MapSet.to_list(caps)

        if has_current_self_license?(caps_list, uri) do
          persist(uri, caps)
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  # ====================================================================
  # Backfill (the #189 PR-2 D1 migration transition — codex spec-review F1)
  # ====================================================================

  @doc """
  The DEDICATED, row-locked backfill transition for the explicit migration
  (`mix ezagent.identity.backfill`) — NOT the generic `persist/2` mirror nor
  `update/2`.

  It reconciles the store row for `uri` from `legacy_caps` (the complete
  cap set read from the LEGACY authoritative source — `users.caps_json` /
  the snapshot `:identity` slice), enforcing the store's resurrection guard
  under a `FOR UPDATE` lock:

    * freshly verifies the self-license against the CURRENT authority
      generation (`has_current_self_license?/2`) — presence in the legacy
      caps is NOT enough (a revocation only bumps the generation and leaves
      stale licenses behind);
    * a license-valid principal → `active` (grandfathered activation, the
      store's second legitimate `active` proof; `provisioning_receipt` stays
      `nil`);
    * a KNOWN principal with NO current-valid license → a durable
      `revoked_unprovisioned` row, NEVER absent and NEVER `active` (leaving
      it absent is unsafe — a later stale legacy mirror write could recreate
      it `active`; codex F1);
    * an existing `active` row that is no longer license-valid → DOWNGRADED
      to `revoked_unprovisioned`;
    * a `revoked_unprovisioned` / `tombstoned` row → NEVER upgraded (only an
      authenticated `reprovision/4` restores it), tombstones preserved.

  Idempotent: safe to re-run; re-running never upgrades a
  `revoked_unprovisioned` / `tombstoned` row to `active`. Returns
  `{:ok, resulting_status}` for per-URI operator reporting.
  """
  @spec backfill(URI.t() | String.t(), [Capability.t()] | MapSet.t(Capability.t())) ::
          {:ok, status()} | {:error, term()}
  def backfill(uri, caps) do
    uri_key = key(uri)
    workspace = workspace_key(uri)
    caps_list = Enum.to_list(caps)
    encoded = encode_caps(caps_list)

    case Repo.transaction(fn -> backfill_locked(uri, uri_key, workspace, encoded, caps_list) end) do
      {:ok, status} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  # Shares the `persist_changes/3` decision AND the atomic `licensed_under_lock?/2`
  # guard with the shadow `persist/2` so the "active iff current-valid
  # self-license" invariant has ONE structural home, verified inside the
  # transaction under the authority-row lock (codex impl-review finding 1: the
  # verify must be atomic with the write — a writer, backfill OR shadow, can
  # never produce an active row for a license-invalid principal, and a
  # concurrent regenesis cannot race a stale license back to `active`). The
  # backfill is a DISTINCT entry point (its own transaction + status return) as
  # the review requires.
  defp backfill_locked(uri, uri_key, workspace, encoded, caps_list) do
    with :ok <- ensure_row(uri_key, workspace),
         row when not is_nil(row) <- lock_row(uri_key),
         licensed? <- licensed_under_lock?(uri, caps_list),
         changes <- persist_changes(row, encoded, licensed?),
         {:ok, updated} <- row |> Ecto.Changeset.change(changes) |> Repo.update() do
      decode_status(updated.identity_status)
    else
      nil -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  #189 PR-3 FIX 3 — materialize a durable `revoked_unprovisioned` row for a URI
  that has AUTHORITY HISTORY but NO store row (a pre-cutover ephemeral principal
  — created, then revoked/cleared — whose durable creation fact survives only in
  `kind_cap_authorities`). The cutover backfill enumerates authority-history
  URIs and adopts the absent ones so the store carries an explicit ever-created,
  non-active row for them (NEVER `active`: it carries no license and stays inert
  until an authenticated re-provision).

  STRICTLY absent-only and idempotent: it takes a `FOR UPDATE` lock and writes
  ONLY when no row exists — it NEVER touches (never downgrades, never clobbers)
  an EXISTING row, so a currently-`active` valid principal or a `tombstoned`
  record is left exactly as it was. Returns `{:ok, :adopted}` (wrote a fresh
  `revoked_unprovisioned` row) or `{:ok, :present}` (a row already existed —
  nothing done).
  """
  @spec adopt_absent_authority_history(URI.t() | String.t()) ::
          {:ok, :adopted | :present} | {:error, term()}
  def adopt_absent_authority_history(uri) do
    uri_key = key(uri)
    workspace = workspace_key(uri)

    Repo.transaction(fn ->
      case lock_row(uri_key) do
        nil ->
          %__MODULE__{}
          |> Ecto.Changeset.change(
            uri: uri_key,
            workspace_uri: workspace,
            identity_status: "revoked_unprovisioned",
            caps_json: "[]"
          )
          |> Repo.insert()
          |> case do
            {:ok, _row} -> :adopted
            {:error, reason} -> Repo.rollback(reason)
          end

        _existing ->
          :present
      end
    end)
    |> case do
      {:ok, outcome} -> {:ok, outcome}
      {:error, reason} -> {:error, reason}
    end
  end

  # ====================================================================
  # Provisioning API (additive in PR-1 — no runtime caller yet)
  # ====================================================================

  @doc """
  Genuine provision (the `:created`-with-receipt transition): activate
  `uri` with the complete cap set (incl. a freshly minted self-license) and
  the authenticated receipt. Idempotent re-activation of an `active` row
  (with a FRESH receipt — receipts are single-use); REJECTED when the URI
  is `tombstoned` (only `reprovision/4` passes that).

  Required opts: `:actor` — the authenticated operator performing the
  provision; the receipt must be issued to that actor AND the actor must
  pass `Ezagent.Identity.AdminAuthority.admin?/1`.
  """
  @spec provision(
          URI.t() | String.t(),
          [Capability.t()] | MapSet.t(Capability.t()),
          ProvisioningReceipt.t(),
          keyword()
        ) :: :ok | {:error, term()}
  def provision(uri, caps, %ProvisioningReceipt{} = receipt, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with :ok <- require_receipt(receipt, uri, :provision, caps, actor) do
      activate_locked(uri, caps, receipt, fn
        %{identity_status: "tombstoned"} -> {:error, :tombstoned}
        _row -> :ok
      end)
    end
  end

  @doc """
  Explicit re-provision (authenticated operator op): the ONLY transition out
  of `revoked_unprovisioned` / `tombstoned` — mints a new self-license
  (caller supplies the new complete cap set), activates, and records the
  fresh receipt. Required opts: `:actor` (see `provision/4`).
  """
  @spec reprovision(
          URI.t() | String.t(),
          [Capability.t()] | MapSet.t(Capability.t()),
          ProvisioningReceipt.t(),
          keyword()
        ) :: :ok | {:error, term()}
  def reprovision(uri, caps, %ProvisioningReceipt{} = receipt, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with :ok <- require_receipt(receipt, uri, :reprovision, caps, actor) do
      activate_locked(uri, caps, receipt, fn
        %{identity_status: "active"} -> {:error, :already_active}
        _row -> :ok
      end)
    end
  end

  @doc """
  Regenesis (revoke): `active → revoked_unprovisioned`. The cap set is kept
  (its self-license is already invalidated by the authority generation
  rotation); the STATUS is what makes restart deny the holder. Monotone —
  a `tombstoned` row cannot transition back.
  """
  @spec revoke_provisioning(URI.t() | String.t()) :: :ok | {:error, term()}
  def revoke_provisioning(uri) do
    transition_locked(uri, nil, fn
      %{identity_status: "active"} -> {:ok, [identity_status: "revoked_unprovisioned"]}
      %{identity_status: "revoked_unprovisioned"} -> {:ok, []}
      %{identity_status: "tombstoned"} -> {:error, :tombstoned}
    end)
  end

  @doc """
  Destroy: `* → tombstoned`. Terminal without a fresh authenticated
  re-provision. Creates the row when absent (a destroyed URI leaves a
  tombstone even if it never had a mirrored cap set).
  """
  @spec tombstone(URI.t() | String.t()) :: :ok | {:error, term()}
  def tombstone(uri) do
    transition_locked(uri, nil, fn
      %{identity_status: "tombstoned"} -> {:ok, []}
      _row -> {:ok, [identity_status: "tombstoned", caps_json: "[]"]}
    end)
  end

  # The guarded active-transition for `provision/4` / `reprovision/4`. Inside
  # ONE transaction: lock the identity row, run the state precheck, then require
  # a CURRENT-valid self-license verified UNDER the authority-row lock, atomic
  # with the write (codex impl-review finding 1: a valid `ProvisioningReceipt`
  # attests to the cap-set DIGEST + actor, NOT to license currency — so a
  # receipt alone could otherwise activate a revoked-generation principal, and a
  # concurrent regenesis could race a stale license to `active`). Only then is
  # the single-use receipt consumed and the row activated. `precheck_fun`
  # returns `:ok` to proceed or `{:error, reason}` to reject on the locked row's
  # current status.
  defp activate_locked(uri, caps, receipt, precheck_fun) do
    uri_key = key(uri)
    workspace = workspace_key(uri)
    caps_list = Enum.to_list(caps)

    case Repo.transaction(fn ->
           with :ok <- ensure_row(uri_key, workspace),
                row when not is_nil(row) <- lock_row(uri_key),
                :ok <- precheck_fun.(row),
                true <-
                  licensed_under_lock?(uri, caps_list) || {:error, :no_current_self_license},
                :ok <- maybe_consume(receipt),
                {:ok, _row} <-
                  row |> Ecto.Changeset.change(activate_changes(caps, receipt)) |> Repo.update() do
             :ok
           else
             {:error, reason} -> Repo.rollback(reason)
             nil -> Repo.rollback(:not_found)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp activate_changes(caps, receipt) do
    [
      caps_json: encode_caps(caps),
      identity_status: "active",
      provisioning_receipt: ProvisioningReceipt.to_json(receipt)
    ]
  end

  # F3: a receipt must (1) verify (signature + subject + transition + TTL),
  # (2) be bound to THIS cap set (digest), (3) be issued to the
  # authenticated actor, and (4) the actor must be an authorized operator
  # (`AdminAuthority.admin?/1`, the same predicate the operator read-plane
  # gates on — fail-closed).
  defp require_receipt(receipt, uri, transition, caps, actor) do
    with true <-
           ProvisioningReceipt.valid_for?(receipt, uri, transition, caps) ||
             {:error, :invalid_provisioning_receipt},
         true <- actor_matches?(receipt, actor) || {:error, :unauthorized_actor},
         true <- authorized_actor?(actor) || {:error, :unauthorized_actor} do
      :ok
    end
  end

  defp actor_matches?(receipt, %URI{} = actor), do: receipt.actor_uri == key(actor)
  defp actor_matches?(_receipt, _actor), do: false

  defp authorized_actor?(%URI{} = actor), do: Ezagent.Identity.AdminAuthority.admin?(actor)
  defp authorized_actor?(_actor), do: false

  # Row-locked status transition. `fun` inspects the locked row (which the
  # `ensure_row` upsert guarantees exists) and returns `{:ok, changes}` or
  # `{:error, reason}`. When a receipt is given it is CONSUMED (single-use)
  # inside the same transaction — a replay or a failed update rolls the
  # whole transition back.
  defp transition_locked(uri, receipt, fun) do
    uri_key = key(uri)
    workspace = workspace_key(uri)

    case Repo.transaction(fn ->
           with :ok <- ensure_row(uri_key, workspace),
                row when not is_nil(row) <- lock_row(uri_key),
                {:ok, changes} <- fun.(row),
                :ok <- maybe_consume(receipt),
                {:ok, _row} <- row |> Ecto.Changeset.change(changes) |> Repo.update() do
             :ok
           else
             {:error, reason} -> Repo.rollback(reason)
             nil -> Repo.rollback(:not_found)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_consume(nil), do: :ok
  defp maybe_consume(%ProvisioningReceipt{} = receipt), do: ProvisioningReceipt.consume(receipt)

  # ====================================================================
  # Internals
  # ====================================================================

  defp key(%URI{} = uri), do: uri |> Ezagent.URI.instance() |> URI.to_string()

  defp key(uri) when is_binary(uri),
    do: uri |> Ezagent.URI.new!() |> Ezagent.URI.instance() |> URI.to_string()

  # Per-tenant column: the entity URI's own workspace. Cross-cutting URIs
  # (`system://`, …) resolve to `:any` and land in the structural system
  # sink (the `Kind.Snapshot.save_now` precedent, SPEC #324 rev 3).
  defp workspace_key(%URI{} = uri), do: uri |> Ezagent.URI.workspace_of() |> workspace_to_string()
  defp workspace_key(uri) when is_binary(uri), do: uri |> Ezagent.URI.new!() |> workspace_key()

  defp workspace_to_string(%URI{} = workspace), do: URI.to_string(workspace)
  defp workspace_to_string(:any), do: Ezagent.URI.workspace(:system) |> URI.to_string()
  defp workspace_to_string(_other), do: Ezagent.URI.workspace(:system) |> URI.to_string()

  defp user_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  defp user_uri?(uri) when is_binary(uri), do: user_uri?(Ezagent.URI.new!(uri))
  defp user_uri?(_uri), do: false

  defp skip_kind?(nil), do: false

  defp skip_kind?(kind_module) when is_atom(kind_module) do
    Ezagent.Kind.persistence_of(kind_module) in [:ephemeral, :external]
  rescue
    _ -> false
  end

  # Accept every on-disk / in-memory `:identity` slice shape and extract the
  # caps MapSet: Lifecycle two-container `%{state: _, transients: _}`,
  # persisted single-key `%{state: _}`, legacy flat `%{caps: _}`.
  defp slice_caps(%{state: state, transients: _}) when is_map(state), do: slice_caps(state)

  defp slice_caps(%{state: state} = slice) when is_map(state) and map_size(slice) == 1,
    do: slice_caps(state)

  defp slice_caps(%{caps: %MapSet{} = caps}), do: caps
  defp slice_caps(%{caps: caps}) when is_list(caps), do: MapSet.new(caps)
  defp slice_caps(_other), do: nil

  defp encode_caps(caps) do
    caps |> Enum.map(&Capability.to_map/1) |> Jason.encode!()
  end

  defp decode_caps(nil), do: []
  defp decode_caps(""), do: []

  defp decode_caps(json) do
    case Jason.decode(json) do
      {:ok, caps} when is_list(caps) -> Enum.map(caps, &Capability.from_map/1)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp now_usec, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  # Total string→atom decode for the persisted `identity_status` enum. The status
  # is stored as a STRING (the `field(:identity_status, :string)` schema and every
  # write literal) while the read APIs (`status/1`, `status_result/1`,
  # `backfill/2`) hand back a `status()` ATOM. Each of the three known atoms is a
  # COMPILE-TIME LITERAL here, so it lands in THIS module's atom chunk and loading
  # `Store` alone interns it — the decode never depends on some OTHER module having
  # been loaded first.
  #
  # This REPLACES `String.to_existing_atom/1`, which was load-order-fragile: the
  # `@type status` typespec does NOT emit its atoms into the loadable atom chunk,
  # and the only other `:revoked_unprovisioned` occurrences are guard literals in
  # `Ezagent.Identity.{PreEpochRemint, FleetParity}`. So on a release node that ran
  # the cutover backfill BEFORE those modules were loaded,
  # `String.to_existing_atom("revoked_unprovisioned")` raised `ArgumentError`
  # ("not an already existing atom") and crashed `EzagentCore.Release.identity_cutover/1`
  # at Step 1/3 backfill (the canary catch) — on the first entity whose backfilled
  # status is `revoked_unprovisioned`, which is exactly a status this store WRITES
  # (a licence-invalid principal / an adopted authority-history URI). The read of
  # the store's own persisted enum must not hinge on incidental interning.
  #
  # An UNRECOGNIZED status string is a corrupt / schema-drifted row: fail LOUD with
  # a clear domain message — NEVER a silent `nil`, NEVER a stale-atom guess. This is
  # the authoritative cap-read path, so a misdecoded status must never be swallowed
  # (an unknown status that resolved to `nil` would read as "absent" and could let a
  # legacy self-license authorize a principal the store means to deny). The raise
  # can propagate past `status_result/1`'s `{:ok, _} | :error` contract, but ONLY
  # for genuine corruption; the three known statuses never raise.
  @spec decode_status(String.t()) :: status()
  defp decode_status("active"), do: :active
  defp decode_status("revoked_unprovisioned"), do: :revoked_unprovisioned
  defp decode_status("tombstoned"), do: :tombstoned

  defp decode_status(other) do
    raise ArgumentError,
          "Ezagent.EntityCaps.Store: unknown identity_status #{inspect(other)} " <>
            "(expected \"active\" | \"revoked_unprovisioned\" | \"tombstoned\")"
  end

  # ====================================================================
  # Self-license currency (the #189 PR-2 write-boundary + backfill guard)
  # ====================================================================

  @doc false
  # Whether `caps` carries a `:self_license` for `uri` that verifies against the
  # URI's CURRENT authority generation — the ONE predicate that distinguishes a
  # genuinely-current holder from a revoked one whose stale license still sits
  # in the legacy source. Mirrors the legacy reader gate
  # (`EntityCaps.current_self_license?/2`) so the store never trusts a license
  # the authorization plane would reject. Fail-closed on any error.
  #
  # PURE PREDICATE — lock-free, so it is safe to call OUTSIDE a transaction (the
  # fleet-parity holder scan, the backfill `--dry-run`). The atomic-with-write
  # guard is `licensed_under_lock?/2`, which locks the authority row FIRST; do
  # NOT push the lock in here (a `FOR SHARE` outside a transaction is a no-op).
  @spec has_current_self_license?([Capability.t()], URI.t() | String.t()) :: boolean()
  def has_current_self_license?(caps, uri) when is_list(caps) do
    entity = uri_struct(uri)
    Enum.any?(caps, &current_self_license?(&1, entity))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # The SINGLE guarded active-transition primitive (codex impl-review finding 1):
  # inside the caller's OPEN transaction, take a `FOR SHARE` lock on the URI's
  # current authority generation, THEN verify the self-license against it. The
  # lock blocks a concurrent `Authority.regenesis/2` (which retires the active
  # row) from interleaving between this verify and the caller's dependent row
  # write, so the "active iff current-valid self-license" decision is atomic with
  # the write. Every path that can set `identity_status: "active"` — `persist/2`,
  # `backfill/2`, `update/2`, `provision/4`, `reprovision/4` — routes its license
  # decision through here. MUST be called inside a `Repo.transaction/1`.
  #
  # (Residual note for re-reviewers: if the store WINS the lock race — verifies
  # gen-N valid, writes `active`, and regenesis bumps to gen N+1 only AFTER this
  # transaction commits — that is ordinary write-shadow staleness, NOT a
  # verify/write TOCTOU: gen N genuinely WAS current at commit time, PR-2 reads
  # stay legacy so it changes no authz outcome, and the quiescent PR-3 backfill +
  # fence reconciles it. The property enforced here is only that regenesis cannot
  # interleave DURING the verify→write window.)
  defp licensed_under_lock?(uri, caps_list) do
    maybe_run_verify_race_seam(uri)
    :ok = Ezagent.Cap.Authority.lock_current_generation(uri_struct(uri))
    has_current_self_license?(caps_list, uri)
  end

  if @p2_verify_race_seam do
    defp maybe_run_verify_race_seam(uri) do
      case Application.get_env(:ezagent_domain_identity, :p2_verify_race_hook) do
        fun when is_function(fun, 1) -> fun.(uri_struct(uri))
        _ -> :ok
      end

      :ok
    end
  else
    defp maybe_run_verify_race_seam(_uri), do: :ok
  end

  defp current_self_license?(%Capability{} = cap, %URI{} = uri) do
    Capability.action_of(cap) == :self_license and
      Ezagent.Cap.Authority.verify_against_current(cap, uri, uri)
  end

  defp current_self_license?(_cap, _uri), do: false

  defp uri_struct(%URI{} = uri), do: Ezagent.URI.instance(uri)

  defp uri_struct(uri) when is_binary(uri),
    do: uri |> Ezagent.URI.new!() |> Ezagent.URI.instance()
end
