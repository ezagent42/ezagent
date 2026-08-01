defmodule Ezagent.IdentityCaps.Store do
  @moduledoc """
  The sole durable authority for every entity's held capability set.

  One row per canonical entity URI holds:

    * `caps_json` — the COMPLETE held-cap set (serialized
      `[Ezagent.Capability.to_map/1]` maps), including the self-license;
    * `identity_status` — `staged | active | revoked_unprovisioned | tombstoned`.
      `staged` exists only between row initialization and the first successful
      Kind genesis; established lifecycle transitions remain monotone
      (`active → revoked_unprovisioned`, `* → tombstoned`);
    * `provisioning_receipt` — the authenticated proof
      (`Ezagent.Identity.ProvisioningReceipt`) that the current `active`
      state was created by genuine provision/re-provision, not a spawn race;
    * `workspace_uri` — the entity URI's workspace (per-tenant gate).

  `kind_cap_authorities` remains the signing-key and generation authority.
  Live identity slices and Kind snapshots are projections of this store and
  are never read as a fallback.
  """

  use Ecto.Schema

  import Ecto.Query

  require Logger

  alias Ezagent.Cap.{GrantArtifact, RevocationLedger}
  alias Ezagent.Capability
  alias Ezagent.Identity.ProvisioningReceipt
  alias EzagentCore.Repo

  @type status :: :staged | :active | :revoked_unprovisioned | :tombstoned

  @primary_key {:uri, :string, autogenerate: false}
  schema "identity_caps" do
    field(:caps_json, :string)
    field(:identity_status, :string, default: "staged")
    field(:provisioning_receipt, :string)
    field(:workspace_uri, :string)

    timestamps(type: :utc_datetime_usec)
  end

  # ====================================================================
  # Reads
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
  A Store row proves a non-user URI is known even when it has no snapshot.
  """
  @spec existence_signal?(URI.t() | String.t()) :: boolean()
  def existence_signal?(uri), do: not user_uri?(uri) and has_row?(uri)

  @doc """
  Fail-closed durable ever-created signal for ephemeral principals.

  For an `:ephemeral` principal `fresh_create?` (the snapshot `ever_created`
  marker) is ALWAYS true (an ephemeral Kind writes no snapshot marker), so THIS
  signal is the SOLE determinant of `:created` vs `:existed` — and a
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
    case fetch_result(uri) do
      {:ok, nil} -> Ezagent.Cap.Authority.has_authority_history?(uri_struct(uri))
      {:ok, %__MODULE__{}} -> true
      :error -> true
    end
  end

  # Unlike `fetch/1`, preserve the distinction between absence and a failed DB
  # read so readiness and authorization callers can fail closed.
  defp fetch_result(uri) do
    {:ok, Repo.get(__MODULE__, key(uri))}
  rescue
    _ -> :error
  catch
    _, _ -> :error
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
  Read lifecycle status without collapsing a Store error into absence.
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
  is authoritative about the holder being empty. An absent row also yields `[]`.
  """
  @spec load(URI.t() | String.t()) :: [Capability.t()]
  def load(uri) do
    case fetch(uri) do
      %{identity_status: "active", caps_json: caps_json} ->
        decode_caps(caps_json, workspace_key(uri))

      _ ->
        []
    end
  end

  @doc """
  Read the sole durable capability authority. Missing and unreadable rows are
  explicit errors; callers must fail readiness instead of consulting a
  snapshot or user row.
  """
  @spec fetch_durable_caps(URI.t() | String.t()) ::
          {:ok, [Capability.t()]} | {:error, term()}
  def fetch_durable_caps(uri) do
    case fetch_result(uri) do
      {:ok, nil} ->
        {:error, :identity_caps_missing}

      {:ok, %__MODULE__{identity_status: "active", caps_json: caps_json}} ->
        decode_caps_checked(caps_json, workspace_key(uri))

      {:ok, %__MODULE__{}} ->
        {:ok, []}

      :error ->
        {:error, :store_read_failed}
    end
  end

  @doc """
  Initialize the sole capability row before a principal's first Kind spawn.

  The row is deliberately non-active until the Kind opens its first authority
  generation, mints a current self-license, and calls
  `provision_created_identity/2`. Existing rows are never overwritten.
  """
  @spec initialize(URI.t() | String.t(), [Capability.t()] | MapSet.t(Capability.t())) ::
          :ok | {:error, term()}
  def initialize(uri, caps) when is_list(caps) or is_struct(caps, MapSet) do
    uri_key = key(uri)
    workspace = workspace_key(uri)
    caps_list = Enum.to_list(caps)

    case Repo.transaction(fn ->
           with :ok <- carrier_guard(uri, workspace, caps_list),
                :ok <- Ezagent.Cap.Authority.lock_current_generation(uri_struct(uri)),
                licensed? <- has_current_self_license?(caps_list, uri),
                {inserted, _rows} <-
                  Repo.insert_all(
                    __MODULE__,
                    [
                      %{
                        uri: uri_key,
                        workspace_uri: workspace,
                        identity_status: if(licensed?, do: "active", else: "staged"),
                        caps_json: encode_caps(caps_list),
                        inserted_at: now_usec(),
                        updated_at: now_usec()
                      }
                    ],
                    on_conflict: :nothing,
                    conflict_target: :uri
                  ) do
             if inserted == 1 do
               Ezagent.IdentityCaps.GranteeIndex.reindex_in_txn(uri, caps_list)
               :ok
             else
               Repo.rollback(:identity_caps_already_initialized)
             end
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Load Store-backed spawn input. Only an explicit `staged` row exposes its caps
  to first-spawn initialization. Revoked or tombstoned established principals
  receive no caps, regardless of authority-history timing.
  """
  @spec load_initial(URI.t() | String.t()) :: {:ok, [Capability.t()]} | {:error, term()}
  def load_initial(uri) do
    case fetch_result(uri) do
      {:ok, %__MODULE__{identity_status: "active", caps_json: caps_json}} ->
        decode_caps_checked(caps_json, workspace_key(uri))

      {:ok, %__MODULE__{identity_status: "staged", caps_json: caps_json}} ->
        decode_caps_checked(caps_json, workspace_key(uri))

      {:ok, %__MODULE__{}} ->
        {:ok, []}

      {:ok, nil} ->
        {:error, :identity_caps_missing}

      :error ->
        {:error, :store_read_failed}
    end
  end

  # TEST-ONLY forced Store failure seam. It is compiled out of non-test builds
  # and proves a failed authority write cannot mutate live/snapshot projections.
  @forced_store_failure_seam Mix.env() == :test

  @doc """
  Upsert the complete cap set for `uri`, computing `identity_status`
  structurally from the authoritative caps.

  The invariant this writer enforces: **an `active` row's caps carry a
  current-valid `:self_license`** (verified fresh against the URI's current
  authority generation via `Ezagent.Cap.Authority.verify_against_current/3` —
  mere presence in the caps is not enough; a revocation bumps the generation
  and leaves stale licenses behind). No write can create or keep an `active`
  row for a license-invalid principal:

    * fresh row — `active` iff the caps carry a current-valid self-license,
      else `revoked_unprovisioned` (the URI is inert until an authenticated
      re-provision; NEVER left silently `active`);
    * existing `active` row — persist the caps, but DOWNGRADE to
      `revoked_unprovisioned` when the mirrored set no longer carries a
      current-valid self-license;
    * existing `revoked_unprovisioned` — persist the caps for observability but
      NEVER upgrade the status (only `reprovision/4` leaves that state);
    * existing `tombstoned` — preserved untouched.

  This write does NOT consume a receipt and does NOT change
  a `revoked`/`tombstoned` lifecycle back to `active`. An `active` row created
  here carries `provisioning_receipt: nil` — legitimate under the store's
  proof model: an `active` row is proven either by a consumed
  `ProvisioningReceipt` OR by a current-valid self-license in its caps
  ("grandfathered" activation). The write-boundary guard enforces the latter.
  """
  @spec persist(URI.t() | String.t(), [Capability.t()] | MapSet.t(Capability.t())) ::
          :ok | {:error, term()}
  if @forced_store_failure_seam do
    def persist(uri, caps) when is_list(caps) or is_struct(caps, MapSet) do
      case Application.get_env(:ezagent_domain_identity, :forced_store_failure_uris) do
        nil ->
          do_persist(uri, caps)

        uris ->
          if key(uri) in uris do
            {:error, {:forced_store_failure, key(uri)}}
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

    case Repo.transaction(fn -> persist_locked(uri, uri_key, workspace, caps_list) end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The self-license verification runs INSIDE this transaction, under the
  # authority-row lock (`licensed_under_lock?/2`), so a concurrent
  # `Authority.regenesis/2` cannot rotate the generation between the verify and
  # this write (codex impl-review finding 1 — the verify/write race). A row is
  # never `active` unless a current-valid self-license holds at write time.
  defp persist_locked(uri, uri_key, workspace, caps_list) do
    with :ok <- ensure_row(uri_key, workspace),
         row when not is_nil(row) <- lock_row(uri_key),
         :ok <- carrier_guard(uri, workspace, caps_list),
         licensed? <- licensed_under_lock?(uri, caps_list),
         changes <- persist_changes(row, encode_caps(caps_list), licensed?),
         {:ok, _row} <- row |> Ecto.Changeset.change(changes) |> Repo.update() do
      # URI-share A2-2 (codex ⓪): the reverse cap index derives from THIS
      # authoritative held-cap write, IN the same transaction — atomic, so a
      # rolled-back commit never leaves the index over-reporting a cap that never
      # durably landed. This is the single confluence of every conferral path
      # (grant / initialization / cold-load reconcile / activation), so no
      # writer is missed.
      Ezagent.IdentityCaps.GranteeIndex.reindex_in_txn(uri, caps_list)
      :ok
    else
      nil -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A `tombstoned` row is terminal — an ordinary write never overwrites it.
  defp persist_changes(%{identity_status: "tombstoned"}, _encoded, _licensed?),
    do: [updated_at: now_usec()]

  # A staged row becomes active only when the complete set carries a current
  # self-license. Ordinary writes cannot turn it into a revoked established row.
  defp persist_changes(%{identity_status: "staged"}, encoded, licensed?) do
    status = if licensed?, do: "active", else: "staged"
    [caps_json: encoded, identity_status: status, updated_at: now_usec()]
  end

  # A `revoked_unprovisioned` row is NEVER upgraded by an ordinary write (only an
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

      case carrier_guard(uri, workspace, caps_list) do
        :ok ->
          licensed? = licensed_under_lock?(uri, caps_list)
          changes = persist_changes(row, encode_caps(caps_list), licensed?)

          case row |> Ecto.Changeset.change(changes) |> Repo.update() do
            {:ok, _row} ->
              # A2-2 codex ⓪ — same-txn reverse-index derive (see `persist_locked`).
              Ezagent.IdentityCaps.GranteeIndex.reindex_in_txn(uri, caps_list)
              :ok

            {:error, reason} ->
              Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    else
      nil -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  Atomically make one signed grant_id durably revoked for `uri`.

  A logical Store match always wins and supplies the trusted signed artifact;
  caller-controlled protocol metadata is ignored. Without a logical match, the
  caller must provide an exact current signed artifact issued to this holder.
  The marker, Store removal, pending-delivery cancellation, and reverse-index
  rebuild commit in one Repo transaction.
  """
  @spec revoke_cap(URI.t() | String.t(), Capability.t()) ::
          {:ok, Capability.t()} | {:error, term()}
  def revoke_cap(uri, %Capability{} = caller_cap) do
    uri = uri_struct(uri)
    uri_key = key(uri)
    workspace = workspace_key(uri)

    case Repo.transaction(fn -> revoke_cap_locked(uri, uri_key, workspace, caller_cap) end) do
      {:ok, %Capability{} = resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, reason}
    end
  end

  defp revoke_cap_locked(uri, uri_key, workspace, caller_cap) do
    row = lock_row(uri_key)

    with {:ok, stored_caps} <- locked_caps(row),
         {:ok, resolved} <- resolve_revocation_artifact(uri, stored_caps, caller_cap),
         {:ok, updated} <- Capability.revoke(MapSet.new(stored_caps), resolved),
         :ok <- mark_revoked_grant(workspace, uri_key, resolved),
         :ok <- persist_revoked_caps(row, uri, MapSet.to_list(updated)),
         :ok <-
           Ezagent.Cap.DeliveryOutbox.cancel_pending_grant_in_txn(
             workspace,
             uri_key,
             Map.get(resolved, :grant_id) || ""
           ) do
      resolved
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp locked_caps(nil), do: {:ok, []}
  defp locked_caps(%__MODULE__{caps_json: caps_json}), do: decode_caps_checked(caps_json)

  defp resolve_revocation_artifact(uri, stored_caps, %Capability{} = caller_cap) do
    caller_identity = Capability.identity_key(caller_cap)

    case Enum.find(stored_caps, &(Capability.identity_key(&1) == caller_identity)) do
      %Capability{} = stored ->
        {:ok, stored}

      nil ->
        verify_exact_revocation_artifact(uri, caller_cap)
    end
  rescue
    _ -> {:error, :invalid_exact_revocation_artifact}
  end

  defp verify_exact_revocation_artifact(uri, %Capability{} = cap) do
    with {:ok, target} <- Ezagent.Cap.Authority.target_uri(cap),
         true <- Ezagent.Cap.Authority.verify_against_current(cap, uri, target) do
      {:ok, cap}
    else
      _ -> {:error, :invalid_exact_revocation_artifact}
    end
  end

  defp mark_revoked_grant(workspace, holder_uri, %Capability{} = cap) do
    attrs = %{
      grant_id: cap.grant_id,
      workspace_uri: workspace,
      holder_uri: holder_uri,
      cap_identity_key:
        :crypto.hash(:sha256, :erlang.term_to_binary(Capability.identity_key(cap))),
      revoked_at: DateTime.utc_now(),
      target_uri: concrete_target_key(cap),
      key_id: cap.key_id
    }

    case RevocationLedger.mark(attrs) do
      {:ok, _marker} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_revoked_caps(nil, uri, caps) do
    Ezagent.IdentityCaps.GranteeIndex.reindex_in_txn(uri, caps)
  end

  defp persist_revoked_caps(%__MODULE__{} = row, uri, caps) do
    licensed? = licensed_under_lock?(uri, caps)
    changes = persist_changes(row, encode_caps(caps), licensed?)

    case row |> Ecto.Changeset.change(changes) |> Repo.update() do
      {:ok, _updated} -> Ezagent.IdentityCaps.GranteeIndex.reindex_in_txn(uri, caps)
      {:error, reason} -> {:error, reason}
    end
  end

  defp concrete_target_key(%Capability{instance: %URI{} = target}),
    do: Ezagent.URI.stable_key(target)

  defp concrete_target_key(_cap), do: nil

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
  # Actor projection seams
  # ====================================================================

  @doc """
  Replace a cold live identity projection from the durable Store. An
  established entity with a missing, unreadable, or corrupt Store row refuses
  readiness; snapshots never become a fallback authority.
  """
  @spec reconcile_cold_load_identity(URI.t() | String.t(), atom(), term()) ::
          {:replace, term()} | :keep | {:error, {:identity_reconcile_unreadable, term()}}
  def reconcile_cold_load_identity(uri, create_freshness, identity_slice) do
    with :existed <- create_freshness,
         %MapSet{} <- slice_caps(identity_slice) do
      case fetch_durable_caps(uri) do
        {:ok, store_caps} ->
          {:replace, put_slice_caps(identity_slice, MapSet.new(store_caps))}

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
  Write the durable identity on genuine creation for every principal.

  An ephemeral Kind's slice is never snapshot-persisted. This explicit,
  fail-closed boot-path write makes the ephemeral principal's
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
          activate_created_identity(uri, caps_list)
        else
          {:error, :no_current_self_license}
        end

      _ ->
        {:error, :invalid_identity_slice}
    end
  end

  defp activate_created_identity(uri, caps_list) do
    uri_key = key(uri)
    workspace = workspace_key(uri)

    case Repo.transaction(fn ->
           with :ok <- ensure_row(uri_key, workspace),
                row when not is_nil(row) <- lock_row(uri_key),
                true <- row.identity_status == "staged" || {:error, :not_staged},
                {:ok, staged_caps} <- decode_caps_checked(row.caps_json, workspace),
                merged_caps <- merge_caps_by_identity(staged_caps, caps_list),
                :ok <- carrier_guard(uri, workspace, merged_caps),
                true <-
                  licensed_under_lock?(uri, merged_caps) ||
                    {:error, :no_current_self_license},
                {:ok, _updated} <-
                  row
                  |> Ecto.Changeset.change(
                    caps_json: encode_caps(merged_caps),
                    identity_status: "active",
                    updated_at: now_usec()
                  )
                  |> Repo.update() do
             Ezagent.IdentityCaps.GranteeIndex.reindex_in_txn(uri, merged_caps)
             :ok
           else
             nil -> Repo.rollback(:not_found)
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
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
                :ok <- carrier_guard(uri, workspace, caps_list),
                true <-
                  licensed_under_lock?(uri, caps_list) || {:error, :no_current_self_license},
                :ok <- maybe_consume(receipt),
                {:ok, _row} <-
                  row |> Ecto.Changeset.change(activate_changes(caps, receipt)) |> Repo.update() do
             # A2-2 codex ⓪ (cc review 1) — the provision/reprovision writer is a
             # conferral path too; derive the reverse index IN this txn so an
             # activate (esp. a reprovision with a REDUCED set) never leaves a
             # stale/over-reporting index row. Same-txn as the other 3 writers.
             Ezagent.IdentityCaps.GranteeIndex.reindex_in_txn(uri, caps_list)
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

  # P2 per-cap revocation: the ONE shared validator for every cap-set writer.
  # Every caller invokes it only after taking the holder row's `FOR UPDATE`
  # lock and before encoding, updating, or reindexing the new set.
  defp carrier_guard(uri, workspace, caps_list) do
    receiver = uri_struct(uri)

    if Enum.all?(caps_list, &Ezagent.Cap.storable_for?(&1, receiver)) do
      Ezagent.Cap.RevocationLedger.ensure_unrevoked(workspace, caps_list)
    else
      {:error, :invalid_capability_protocol}
    end
  end

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

  # Accept every on-disk / in-memory `:identity` slice shape and extract the
  # caps MapSet: Lifecycle two-container `%{state: _, transients: _}`,
  # persisted single-key `%{state: _}`, legacy flat `%{caps: _}`.
  defp slice_caps(%{state: state, transients: _}) when is_map(state), do: slice_caps(state)

  defp slice_caps(%{state: state} = slice) when is_map(state) and map_size(slice) == 1,
    do: slice_caps(state)

  defp slice_caps(%{caps: %MapSet{} = caps}), do: caps
  defp slice_caps(%{caps: caps}) when is_list(caps), do: MapSet.new(caps)
  defp slice_caps(_other), do: nil

  defp merge_caps_by_identity(staged_caps, live_caps) do
    staged_caps
    |> Enum.concat(live_caps)
    |> Enum.reduce(%{}, fn cap, by_identity ->
      Map.put(by_identity, Capability.identity_key(cap), cap)
    end)
    |> Map.values()
  end

  defp encode_caps(caps) do
    caps |> Enum.map(&Capability.to_map/1) |> Jason.encode!()
  end

  defp decode_caps(nil), do: []
  defp decode_caps(""), do: []

  defp decode_caps(json) do
    case decode_caps_checked(json) do
      {:ok, caps} -> caps
      {:error, :invalid_caps_json} -> []
    end
  end

  defp decode_caps(json, workspace) do
    case decode_caps_checked(json, workspace) do
      {:ok, caps} -> caps
      {:error, _reason} -> []
    end
  end

  defp decode_caps_checked(nil), do: {:error, :invalid_caps_json}
  defp decode_caps_checked(""), do: {:error, :invalid_caps_json}

  defp decode_caps_checked(json) do
    case Jason.decode(json) do
      {:ok, nil} -> {:error, :invalid_caps_json}
      {:ok, caps} when is_list(caps) -> decode_artifact_maps(caps)
      _ -> {:error, :invalid_caps_json}
    end
  rescue
    _ -> {:error, :invalid_caps_json}
  end

  defp decode_caps_checked(json, workspace) do
    with {:ok, caps} <- decode_caps_checked(json),
         :ok <- RevocationLedger.ensure_unrevoked(workspace, caps) do
      {:ok, caps}
    end
  end

  defp decode_artifact_maps(serialized) do
    serialized
    |> Enum.reduce_while({:ok, []}, fn encoded, {:ok, artifacts} ->
      case GrantArtifact.from_map(encoded) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | artifacts]}}
        {:error, _reason} -> {:halt, {:error, :invalid_caps_json}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      {:error, :invalid_caps_json} = error -> error
    end
  end

  defp now_usec, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  # Total string-to-atom decode for the persisted `identity_status` enum. Known
  # atoms are compile-time literals in this module, so decoding is independent of
  # application load order. Unknown values are corrupt schema state and fail loud.
  @spec decode_status(String.t()) :: status()
  defp decode_status("active"), do: :active
  defp decode_status("staged"), do: :staged
  defp decode_status("revoked_unprovisioned"), do: :revoked_unprovisioned
  defp decode_status("tombstoned"), do: :tombstoned

  defp decode_status(other) do
    raise ArgumentError,
          "Ezagent.IdentityCaps.Store: unknown identity_status #{inspect(other)} " <>
            "(expected \"staged\" | \"active\" | \"revoked_unprovisioned\" | \"tombstoned\")"
  end

  # ====================================================================
  # Self-license currency
  # ====================================================================

  @doc false
  # Whether `caps` carries a `:self_license` for `uri` that verifies against the
  # URI's CURRENT authority generation — the predicate that distinguishes a
  # genuinely current holder from a revoked one whose stale license remains.
  # Fail-closed on any error.
  #
  # This predicate is lock-free. Atomic writes use `licensed_under_lock?/2`, which
  # locks the authority row first; `FOR SHARE` outside a transaction is a no-op.
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
  # `update/2`, `provision/4`, `reprovision/4` — routes its license
  # decision through here. MUST be called inside a `Repo.transaction/1`.
  #
  # (Residual note for re-reviewers: if the store WINS the lock race — verifies
  # gen-N valid, writes `active`, and regenesis bumps to gen N+1 only AFTER this
  # transaction commits — that is an ordinary later revocation, not a
  # verify/write TOCTOU: gen N genuinely was current at commit time. The
  # property enforced here is only that regenesis cannot
  # interleave DURING the verify→write window.)
  defp licensed_under_lock?(uri, caps_list) do
    :ok = Ezagent.Cap.Authority.lock_current_generation(uri_struct(uri))
    has_current_self_license?(caps_list, uri)
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
