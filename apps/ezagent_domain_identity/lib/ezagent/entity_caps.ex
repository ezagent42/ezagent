defmodule Ezagent.EntityCaps do
  @moduledoc """
  Storage facade for an entity's inbound capability set.

  The physical stores remain intentionally split: User caps are durable in
  `users.caps_json`; every other entity uses its snapshot-backed `:identity`
  slice. Callers use this module so that split cannot leak into authorization,
  UI, or orchestration code.

  #189 PR-1 (ADDITIVE): the unified per-entity identity-caps store
  (`Ezagent.EntityCaps.Store`) is populated as a WRITE-SHADOW of BOTH legacy
  stores via dual-write (`users.caps_json` writes, the Kind snapshot write
  chokepoints, and direct `SnapshotStore` writes).

  #189 PR-3 (read-cutover): `load_persisted/1` — the COLD durable read behind
  the principal-axis authorization gate (`Cap.Authorize.principal_current?` →
  `Identity.read_held_caps/1`) — consults the store as AUTHORITATIVE
  (`Store.fetch_durable_caps/1`) ONLY once the cutover epoch is active
  (`Ezagent.Identity.Cutover.active?/0`; FIX 5). A legacy fallback applies ONLY
  to a SUCCESSFULLY-ABSENT row; a PRESENT non-active store row is authoritative-
  empty (no fallback); a store READ ERROR DENIES (`[]`), never falls back (FIX
  2). Before the epoch — and on any unreadable epoch (fail-closed) — the read is
  PR-1 legacy-authoritative and never consults the store. The live-first
  `load/1` slice read is unchanged (self-dispatch routes through
  `load_persisted/1`; both remain gen-gated by `verified/2`).

  `load/1` is receiver-aware and live-first. It reads a live Identity slice when
  one exists, then falls back to the durable store selected by the entity type.
  `load_persisted/1` deliberately skips the live process for non-blocking reads
  from inside another Kind callback.

  The mutation functions are storage operations, not authorization decisions.
  User-initiated grants and revokes must still enter through
  `Ezagent.Identity.Grant`; `grant/2` accepts only an artifact that verifies for
  the named receiver, and `revoke/2` can only remove authority.

  Return shapes are stable:

  * `load/1` and `load_persisted/1` return a verified capability list; a missing
    row or snapshot is `[]`.
  * `persist/2`, `grant/2`, and `revoke/2` return `:ok` or `{:error, reason}`.
  """

  require Logger

  alias Ezagent.{
    Capability,
    Cmd,
    Kind,
    Lifecycle,
    ReadyGate,
    Router,
    SnapshotStore,
    SpawnRegistry
  }

  alias Ezagent.EntityCaps.{Revocations, Store, UserStore}

  @type caps :: [Capability.t()] | MapSet.t(Capability.t())

  @doc "Load the entity's current verified caps, preferring a live Identity slice."
  @spec load(URI.t() | String.t()) :: [Capability.t()]
  def load(uri) do
    uri = parse_uri(uri)

    case load_checked(uri) do
      {:ok, caps} -> caps
      {:error, _reason} -> []
    end
  end

  defp load_checked(uri) do
    cond do
      fenced?(uri) ->
        {:ok, []}

      Kind.self?(uri) ->
        # `Cap.authorize/3` runs inside the target Kind. When the target is also
        # the authenticated holder, a live-first slice read would call the current
        # GenServer synchronously and fail closed as `:holder_revoked`. The
        # marker-bearing snapshot / user projection is the independently stored
        # copy of the same Identity slice and avoids that self-call without
        # trusting the presented candidate caps. (`Kind.read/3` §2.2 point 4 names
        # exactly this `EntityCaps` self case; it serves the durable projection —
        # but EntityCaps needs `verified/2` filtering, so it routes through
        # `load_persisted/1`, whose `read_durable/3` never calls the live process.)
        load_persisted_checked(uri)

      true ->
        # SINGLE-SHOT public read (§2.2 `Kind.read/3`, `spawn: :never`) — the
        # actor-internal-free replacement for the `KindRegistry.lookup` +
        # `Kind.get_slice` reach-in that PRESERVES this loader's fail-CLOSED
        # contract:
        #   * `{:ok, slice}`        — live holder → verified live caps.
        #   * `{:error, :not_live}` — genuinely cold-but-created → durable caps.
        #   * any other `{:error, _}` (e.g. `{:get_slice_exit, _}` — a live holder
        #     that transiently exited the read) → `[]`, never the stale durable set.
        # `read_classified/2` is NOT used here: its bounded retry re-reads after a
        # transiently-failing live pid deregisters, collapsing the fail-closed case
        # into the cold-but-durable case (they become one `{:transient, ...}`).
        case Kind.read(uri, :identity, spawn: :never) do
          {:ok, slice} when is_map(slice) ->
            with {:ok, caps} <- caps_from_slice_checked(slice) do
              verified_checked(caps, uri)
            end

          {:ok, _non_map} ->
            {:error, :invalid_identity_slice}

          {:error, :not_live} ->
            load_persisted_checked(uri)

          {:error, reason} ->
            {:error, {:identity_read_failed, reason}}
        end
    end
  end

  @doc "Load verified caps from the entity's physical durable store without calling a live Kind."
  @spec load_persisted(URI.t() | String.t()) :: [Capability.t()]
  def load_persisted(uri) do
    uri = parse_uri(uri)

    case load_persisted_checked(uri) do
      {:ok, caps} -> caps
      {:error, _reason} -> []
    end
  end

  # #189 PR-3 read-cutover, EPOCH-GATED (FIX 5): the unified
  # `Ezagent.EntityCaps.Store` becomes the AUTHORITATIVE durable holder source
  # for the principal-axis cap read (`Cap.Authorize.principal_current?` →
  # `Identity.read_held_caps/1` → `EntityCaps.load/1` → this cold path on
  # self-dispatch) ONLY once the cutover epoch is active
  # (`Ezagent.Identity.Cutover.status/0`). Only a DEFINITIVE `:inactive` epoch
  # (a genuine pre-cutover node) reads the PR-1 legacy-authoritative source, so
  # merging PR-3 flips no production read until the operator activates the epoch
  # after the fenced backfill + barrier.
  #
  # #189 PR-3 FINAL — an UNREADABLE epoch (`:unknown`) DENIES (`[]`), it does NOT
  # fall back to legacy: a freshly started post-cutover node whose epoch read
  # errors must never re-authorize a cap whose lagging legacy projection missed
  # a post-epoch revoke. Only `:inactive` (DB reachable, definitively no epoch
  # row) takes the legacy path.
  defp load_persisted_checked(uri) do
    if fenced?(uri) do
      {:ok, []}
    else
      case Ezagent.Identity.Cutover.status() do
        :active -> load_persisted_cutover_checked(uri)
        :inactive -> load_legacy_persisted_checked(uri)
        :unknown -> {:error, :identity_epoch_unreadable}
      end
    end
  end

  # POST-EPOCH: store-authoritative. Store-preferred with a legacy fallback ONLY
  # for a SUCCESSFULLY-ABSENT row (`:absent`): a PRESENT non-active row is
  # authoritative-empty (`{:ok, []}`) and NEVER falls back — the store's guarded
  # active-ness (§2, active iff a current-valid self-license) is the source of
  # truth. A store READ ERROR (`{:error, _}`) DENIES (`[]`) — it is NEVER a
  # legacy fallback (FIX 2: read failure is not absence). `verified/2` ALWAYS
  # gen-gates the result regardless of source, so a stale/rotated license — a
  # store-active row left behind by a `regenesis` that only bumped the
  # generation, or a stale legacy license — still loads EMPTY.
  defp load_persisted_cutover_checked(uri) do
    case Store.fetch_durable_caps(uri) do
      {:ok, store_caps} -> verified_checked(store_caps, uri)
      :absent -> load_legacy_persisted_checked(uri)
      {:error, reason} -> {:error, {:identity_store_read_failed, reason}}
    end
  end

  defp load_legacy_persisted_checked(uri) do
    with {:ok, caps} <- legacy_persisted_caps_checked(uri) do
      verified_checked(caps, uri)
    end
  end

  defp legacy_persisted_caps_checked(uri) do
    if user_uri?(uri) do
      UserStore.load_checked(uri)
    else
      snapshot_caps_checked(uri)
    end
  end

  defp fenced?(uri), do: Ezagent.Identity.Offboarding.RevocationFence.fenced?(uri)

  @doc """
  Load the effective capability set: authoritative held capabilities plus
  durable pending absorbs that have not reached the identity slice yet.
  """
  @spec effective_caps(URI.t() | String.t()) ::
          {:ok, [Capability.t()]} | {:error, :effective_caps_read_failed}
  def effective_caps(uri) do
    uri = parse_uri(uri)
    effective_read(uri, &load_checked/1)
  end

  @doc """
  Load the durable effective capability set without consulting a live Kind.
  """
  @spec effective_caps_persisted(URI.t() | String.t()) ::
          {:ok, [Capability.t()]} | {:error, :effective_caps_read_failed}
  def effective_caps_persisted(uri) do
    uri = parse_uri(uri)
    effective_read(uri, &load_persisted_checked/1)
  end

  defp effective_read(uri, held_reader) do
    with {:ok, pending} <- Ezagent.Cap.DeliveryOutbox.list_pending_absorb_caps(uri),
         {:ok, held} <- held_reader.(uri),
         {:ok, effective} <- verified_checked(held ++ pending, uri),
         {:ok, current} <-
           Ezagent.Cap.Authority.filter_current_artifacts_checked(effective, uri) do
      {:ok, Enum.uniq_by(current, &Capability.identity_key/1)}
    else
      {:error, reason} ->
        log_effective_read_failure(uri, reason)
        {:error, :effective_caps_read_failed}

      other ->
        log_effective_read_failure(uri, {:unexpected_result, other})
        {:error, :effective_caps_read_failed}
    end
  rescue
    error ->
      log_effective_read_failure(uri, {:exception, Exception.message(error)})
      {:error, :effective_caps_read_failed}
  catch
    kind, reason ->
      log_effective_read_failure(uri, {kind, reason})
      {:error, :effective_caps_read_failed}
  end

  defp log_effective_read_failure(uri, reason) do
    Logger.error("EntityCaps effective read failed for #{URI.to_string(uri)}: #{inspect(reason)}")
  end

  @doc "Replace the entity's complete cap set in its selected physical store and live slice."
  @spec persist(URI.t() | String.t(), caps()) :: :ok | {:error, term()}
  def persist(uri, caps) do
    uri = parse_uri(uri)

    with :ok <- validate_issued_caps(caps, uri) do
      Lifecycle.with_entity_transition(uri, fn ->
        with :ok <- ensure_mutation_target(uri) do
          dispatch_mutation(uri, :persist_caps, %{caps: Enum.to_list(caps)})
        end
      end)
    end
  end

  @doc "Store a verified capability artifact for the named entity."
  @spec grant(URI.t() | String.t(), Capability.t()) :: :ok | {:error, term()}
  def grant(uri, %Capability{} = cap) do
    uri = parse_uri(uri)

    with :ok <- validate_issued_caps([cap], uri),
         {:ok, [_verified]} <- validate_caps([cap], uri) do
      Lifecycle.with_entity_transition(uri, fn ->
        with :ok <- ensure_mutation_target(uri) do
          dispatch_mutation(uri, :store_cap, %{cap: cap})
        end
      end)
    end
  end

  @doc "Remove the matching capability identity from the named entity."
  @spec revoke(URI.t() | String.t(), Capability.t()) :: :ok | {:error, term()}
  def revoke(uri, %Capability{} = cap) do
    uri = parse_uri(uri)

    Lifecycle.with_entity_transition(uri, fn ->
      with :ok <- ensure_mutation_target(uri) do
        dispatch_mutation(uri, :remove_cap, %{cap: cap})
      end
    end)
  end

  @doc """
  ② P2(b) — durably revoke `cap` from `uri`'s AUTHORITATIVE durable store(s),
  WITHOUT involving the entity's live Kind.

  This is the store-layer half of `Ezagent.Identity.Grant.revoke_cap_via_router/4`:
  a revoke MUST delete the cap from the durable store synchronously/reliably —
  never contingent on messaging a (possibly down or restarting) target process.
  The `:remove_cap` process notification is only a "wake up + re-read" hint; a
  cold/restarted target reconciles from the store state written HERE on load.

  Writes the plane(s) the entity type makes authoritative, mirroring the
  mutation split this facade already owns:

    * user — `users.caps_json` via `UserStore.update/2` (which itself mirrors
      the unified identity-caps store + the reverse grantee index), AND the
      user Kind's snapshot `:identity` slice. The snapshot delete is NOT
      optional: `Identity.activate/2` runs on every cold boot and set-UNIONS
      the snapshot-restored caps with `users.caps_json` (invariant 20), then
      re-persists the union — a cap left in the snapshot would be
      RESURRECTED into both authoritative planes on the holder's next
      restart (observed: the ②-Q2 GAP repro clobbering the store delete).
    * non-user with a snapshot — the snapshot `:identity` slice via
      `SnapshotStore.write/3` (which dual-writes the identity-caps store +
      grantee index), the `clear_snapshot_self_license/1` precedent;
    * non-user without a snapshot but with a store row (e.g. an `:ephemeral`
      principal, whose identity durability IS the store) — a store-only
      `Store.update/2`.

  Idempotent: revoking a cap the store does not hold is `:ok`, and a holder
  with no durable row at all is `:ok` (a revoke never CREATES creation
  evidence for a URI it knows nothing about).
  `Ezagent.Capability.revoke/2`'s `{:error, :cannot_revoke_admin}` propagates
  (fail-closed), as does any store error — an unreadable identity epoch
  (`:unknown`) refuses the mutation rather than risking a stale authoritative
  plane.

  The user-path writes are two non-atomic plane commits (UserStore first —
  the authoritative store must commit before the restore-source cleanup —
  then the snapshot). A crash between them returns `{:error, _}` so the
  caller knows the revoke did not fully commit; a retry is safe (both
  halves are idempotent).

  ## ② P2(c) — the revoke is durable against resurrection (codex must-fixes #1-#3)

  Before ANY plane delete, the revoke commits two fail-closed preconditions:

    1. **Revocation tombstone** (`Ezagent.EntityCaps.Revocations.record/3`) —
       the monotone fence `(holder, cap identity) -> revoked_at`. It is what
       makes the delete durable against STALE WRITERS: a live holder that
       missed the `:remove_cap` hint still carries the cap in memory, and any
       intervening whole-Kind snapshot write would re-add it to the durable
       planes; the fence refuses the artifact at every Store write boundary
       and at `Identity.activate/2`'s invariant-20 union (re-grants pass —
       `Cap.issue/3` re-stamps `granted_at` after the watermark). Recording
       FIRST means a tombstone failure aborts the revoke before any delete
       (fail-closed), and a later delete failure still leaves the fence in
       place (fail-safe, toward denial).
    2. **Pending-delivery cancel** (`DeliveryOutbox.cancel_pending_grants/2`) —
       pending `:store_cap` / `:absorb_cap` outbox rows carrying this cap
       identity are tombstoned `:cancelled`, so a grant buffered while the
       holder was down cannot drain after the revoke and resurrect the cap.

  The user plane delete then runs AUTHORITATIVE (`UserStore.update/3` with
  `source: :store, projection: :authoritative`): the read-modify-write
  sources the current set from the identity-caps Store (never the lagging
  `caps_json` projection), and a `caps_json` projection failure propagates
  as `{:error, _}` instead of being swallowed (must-fix #2).
  """
  @spec revoke_persisted(URI.t() | String.t(), Capability.t()) :: :ok | {:error, term()}
  def revoke_persisted(uri, %Capability{} = cap) do
    uri = parse_uri(uri)

    with :ok <- refuse_admin_invariant(cap),
         :ok <- Revocations.record(uri, cap),
         :ok <- Ezagent.Cap.DeliveryOutbox.cancel_pending_grants(uri, cap) do
      if user_uri?(uri) do
        case UserStore.update(uri, fn caps -> revoke_from_cap_list(caps, cap) end,
               source: :store,
               projection: :authoritative
             ) do
          {:error, :not_found} -> :ok
          :ok -> revoke_user_snapshot(uri, cap)
          {:error, _reason} = error -> error
        end
      else
        revoke_snapshot_persisted(uri, cap)
      end
    end
  end

  # `Capability.revoke/2` refuses the genesis admin invariant — but the
  # tombstone + outbox cancel run BEFORE the plane deletes now, so the
  # refusal must gate FIRST: a recorded tombstone for the admin `:any` cap
  # would fence the root authority itself (its `granted_at` predates every
  # watermark) without any delete ever failing.
  defp refuse_admin_invariant(%Capability{} = cap) do
    if Capability.admin_invariant?(cap), do: {:error, :cannot_revoke_admin}, else: :ok
  end

  @doc false
  @spec clear_self_license_persisted(URI.t() | String.t()) :: :ok | {:error, term()}
  def clear_self_license_persisted(uri) do
    uri = parse_uri(uri)

    if user_uri?(uri) do
      case UserStore.update(uri, fn caps -> {:ok, reject_self_license(caps)} end) do
        {:error, :not_found} -> :ok
        result -> result
      end
    else
      clear_snapshot_self_license(uri)
    end
  end

  @doc false
  @spec verified_set(Enumerable.t(), URI.t() | String.t()) :: MapSet.t(Capability.t())
  def verified_set(caps, uri), do: Ezagent.Cap.verified_set(caps, parse_uri(uri))

  @doc false
  @spec prepare_for_storage(caps(), URI.t() | String.t(), boolean()) ::
          {:ok, [Capability.t()]} | {:error, term()}
  def prepare_for_storage(caps, uri, live?) when is_boolean(live?) do
    uri = parse_uri(uri)

    with {:ok, verified_caps} <- validate_caps(caps, uri),
         {:ok, persistable_caps} <- preserve_derived_caps(uri, verified_caps, live?) do
      {:ok, persistable_caps}
    end
  end

  @doc false
  @spec validate_issued_caps(caps(), URI.t() | String.t()) :: :ok | {:error, term()}
  def validate_issued_caps(caps, uri) when is_list(caps) or is_struct(caps, MapSet) do
    uri = parse_uri(uri)

    if Enum.all?(caps, &issued_for?(&1, uri)) do
      :ok
    else
      {:error, :invalid_cap_artifact}
    end
  end

  def validate_issued_caps(_caps, _uri), do: {:error, :invalid_cap_artifact}

  defp dispatch_mutation(uri, action, args) do
    target = Ezagent.URI.with_action(Ezagent.URI.instance(uri), :identity, action)

    Router.dispatch(%Cmd{
      target: target,
      action: action,
      args: args,
      ctx: %{
        caller: :vm_internal,
        caps: MapSet.new(),
        mode: :call,
        reply: {:caller_inbox, self()}
      },
      origin: :trusted_internal
    })
    |> normalize_dispatch_result()
  end

  defp ensure_mutation_target(uri) do
    with :ok <- ensure_live(uri),
         :ok <- ReadyGate.await(uri, Ezagent.Invocation.activate_budget_ms()) do
      :ok
    else
      {:error, :timeout} -> {:error, :activate_timeout}
      {:error, :not_created} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_live(uri) do
    if user_uri?(uri) do
      if UserStore.exists?(uri) do
        Ezagent.Entity.spawn_principal(uri)
      else
        {:error, :not_found}
      end
    else
      case Ezagent.KindRegistry.lookup(uri) do
        {:ok, _pid} ->
          :ok

        :error ->
          with {:ok, _snapshot} <- SnapshotStore.latest(uri) do
            case SpawnRegistry.ensure_live(uri) do
              {:ok, _status} -> :ok
              {:error, {:already_registered, _winner}} -> :ok
              {:error, _reason} = error -> error
            end
          else
            {:error, :not_found} -> {:error, :not_found}
            {:error, _reason} = error -> error
          end
      end
    end
  end

  defp snapshot_caps(uri) do
    # The sanctioned durable projection of the `:identity` slice (§2.2
    # `Kind.read_durable/3`): snapshot decode + `normalize_slice_view/1`, never
    # the live process. Replaces the `SnapshotStore.latest` reach-in.
    case Kind.read_durable(uri, :identity) do
      {:ok, identity, _meta} when is_map(identity) -> caps_from_slice(identity)
      _ -> []
    end
  end

  defp snapshot_caps_checked(uri) do
    case Kind.read_durable(uri, :identity) do
      {:ok, identity, _meta} when is_map(identity) -> caps_from_slice_checked(identity)
      {:ok, _non_map, _meta} -> {:error, :invalid_identity_slice}
      {:error, :not_created} -> {:ok, []}
      {:error, reason} -> {:error, {:durable_identity_read_failed, reason}}
    end
  end

  defp validate_caps(caps, uri) when is_list(caps) or is_struct(caps, MapSet) do
    caps = Enum.to_list(caps)
    verified = verified_set(caps, uri)

    if Enum.all?(caps, &match?(%Capability{}, &1)) and
         MapSet.size(verified) == length(caps) do
      {:ok, caps |> dedupe_by_identity() |> MapSet.to_list()}
    else
      {:error, :invalid_cap_artifact}
    end
  end

  defp validate_caps(_caps, _uri), do: {:error, :invalid_cap_artifact}

  defp preserve_derived_caps(uri, caps, live) do
    if live or not user_uri?(uri) do
      {:ok, %{caps: derived}} = Ezagent.ActionSet.Identity.create(%{uri: uri, initial_caps: []})

      protected =
        uri
        |> raw_persisted_caps()
        |> Enum.filter(&(Capability.action_of(&1) == :self_license))

      merged =
        derived
        |> Enum.concat(protected)
        |> Enum.reduce(MapSet.new(caps), &replace_by_identity(&2, &1))

      {:ok, MapSet.to_list(merged)}
    else
      protected =
        uri
        |> raw_persisted_caps()
        |> Enum.filter(&(Capability.action_of(&1) == :self_license))

      merged = Enum.reduce(protected, MapSet.new(caps), &replace_by_identity(&2, &1))
      {:ok, MapSet.to_list(merged)}
    end
  end

  defp raw_persisted_caps(uri) do
    if user_uri?(uri), do: UserStore.load(uri), else: snapshot_caps(uri)
  end

  defp revoke_from_cap_list(caps, %Capability{} = cap) when is_list(caps) do
    case Ezagent.Capability.revoke(MapSet.new(caps), cap) do
      {:ok, updated} -> {:ok, MapSet.to_list(updated)}
      {:error, _reason} = error -> error
    end
  end

  # The ONE snapshot read-modify-write seam every mutation above routes
  # through — deliberately the ONLY `SnapshotStore` reach-ins in this module's
  # mutation paths, so the actor-internals boundary ledger (§4.2,
  # frequency-enforced) stays exactly at its frozen count. `fun` transforms
  # the decoded snapshot state; `{:error, :not_found}` (no snapshot row) is
  # returned DISTINCTLY so each caller decides what absence means.
  #
  # NB the row `version` is the Kind's declared SCHEMA version
  # (`Kind.Snapshot.check_version/2` refuses `stored != declared`), NOT an
  # optimistic-concurrency counter — it is rewritten UNCHANGED.
  # (`SnapshotStore.write/3`'s auto-increment default would persist
  # `version + 1` and make the row unloadable on the next cold boot —
  # `:snapshot_version_too_new`. The pre-refactor `version + 1` here was
  # exactly that latent corruption.)
  @spec mutate_snapshot_state(URI.t(), (map() -> {:ok, map()} | {:error, term()})) ::
          :ok | {:error, :not_found | term()}
  defp mutate_snapshot_state(uri, fun) when is_function(fun, 1) do
    case SnapshotStore.latest(uri) do
      {:ok, %{state: state, version: version}} when is_map(state) ->
        with {:ok, updated} <- fun.(state),
             {:ok, _written} <-
               SnapshotStore.write(uri, updated,
                 kind_type: snapshot_kind_type(uri),
                 version: version
               ) do
          :ok
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # User durable revoke, snapshot half: the user Kind's `:on_change` snapshot
  # is the cold-boot restore source for the live identity slice, and
  # `Identity.activate/2` unions it into `users.caps_json` on every start —
  # so the cap must leave the snapshot too, or the next restart resurrects
  # it into every plane. For a user the `SnapshotStore.write/3` dual-write is
  # a no-op (the store skips user URIs — users mirror via `users.caps_json`,
  # which `UserStore.update/2` already wrote). No snapshot at all is `:ok`
  # (nothing to resurrect from).
  defp revoke_user_snapshot(uri, cap) do
    case mutate_snapshot_state(uri, fn state -> remove_snapshot_cap(state, cap) end) do
      {:error, :not_found} -> :ok
      result -> result
    end
  end

  # Non-user durable revoke: the legacy authoritative plane is the snapshot
  # `:identity` slice (`SnapshotStore.write/3` dual-writes the identity-caps
  # store + reverse grantee index in the same write). With NO snapshot, the
  # identity-caps store is the only plane that can still hold the cap (e.g.
  # an `:ephemeral` principal) — update it only when a row EXISTS.
  defp revoke_snapshot_persisted(uri, cap) do
    case mutate_snapshot_state(uri, fn state -> remove_snapshot_cap(state, cap) end) do
      {:error, :not_found} ->
        if Store.has_row?(uri) do
          Store.update(uri, fn caps -> revoke_from_cap_list(caps, cap) end)
        else
          :ok
        end

      result ->
        result
    end
  end

  defp remove_snapshot_cap(state, %Capability{} = cap) do
    case Map.get(state, :identity) do
      %{state: identity_state} = container when is_map(identity_state) ->
        with {:ok, updated_state} <- revoke_from_slice_caps(identity_state, cap) do
          {:ok, Map.put(state, :identity, Map.put(container, :state, updated_state))}
        end

      identity when is_map(identity) ->
        with {:ok, updated_identity} <- revoke_from_slice_caps(identity, cap) do
          {:ok, Map.put(state, :identity, updated_identity)}
        end

      nil ->
        {:ok, state}

      _invalid ->
        {:error, :invalid_identity_snapshot}
    end
  end

  defp revoke_from_slice_caps(identity_state, cap) do
    caps = Map.get(identity_state, :caps, MapSet.new())

    case Ezagent.Capability.revoke(MapSet.new(caps), cap) do
      {:ok, updated} -> {:ok, Map.put(identity_state, :caps, updated)}
      {:error, _reason} = error -> error
    end
  end

  defp clear_snapshot_self_license(uri) do
    case mutate_snapshot_state(uri, &remove_snapshot_self_license/1) do
      {:error, :not_found} -> :ok
      result -> result
    end
  end

  defp remove_snapshot_self_license(state) do
    case Map.get(state, :identity) do
      %{state: identity_state} = container when is_map(identity_state) ->
        updated = Map.update(identity_state, :caps, MapSet.new(), &reject_self_license/1)
        {:ok, Map.put(state, :identity, Map.put(container, :state, updated))}

      identity when is_map(identity) ->
        updated = Map.update(identity, :caps, MapSet.new(), &reject_self_license/1)
        {:ok, Map.put(state, :identity, updated)}

      nil ->
        {:ok, state}

      _invalid ->
        {:error, :invalid_identity_snapshot}
    end
  end

  defp reject_self_license(%MapSet{} = caps) do
    caps
    |> Enum.reject(&(Capability.action_of(&1) == :self_license))
    |> MapSet.new()
  end

  defp reject_self_license(caps) when is_list(caps) do
    Enum.reject(caps, &(Capability.action_of(&1) == :self_license))
  end

  defp reject_self_license(_caps), do: MapSet.new()

  defp snapshot_kind_type(%URI{scheme: "entity"} = uri) do
    case Ezagent.URI.type(uri) do
      {:ok, "agent"} -> :agent
      {:ok, "user"} -> :user
      _ -> :entity
    end
  end

  defp snapshot_kind_type(%URI{scheme: "session"}), do: :session

  defp snapshot_kind_type(%URI{scheme: "template"} = uri) do
    case Ezagent.URI.type(uri) do
      {:ok, "agent"} -> :agent_template
      {:ok, "session"} -> :session_template
      _ -> :template
    end
  end

  defp snapshot_kind_type(_uri), do: :unknown

  defp issued_for?(
         %Capability{signature: signature, key_id: key_id, grantee_uri: %URI{} = grantee},
         uri
       )
       when is_binary(signature) and byte_size(signature) > 0 and is_binary(key_id) and
              byte_size(key_id) > 0,
       do: Ezagent.URI.stable_key(grantee) == Ezagent.URI.stable_key(uri)

  defp issued_for?(_cap, _uri), do: false

  defp dedupe_by_identity(caps) do
    Enum.reduce(caps, %{}, fn cap, acc ->
      Map.put(acc, Capability.identity_key(cap), cap)
    end)
    |> Map.values()
    |> MapSet.new()
  end

  defp replace_by_identity(caps, cap) do
    caps
    |> Enum.reject(&(Capability.identity_key(&1) == Capability.identity_key(cap)))
    |> MapSet.new()
    |> MapSet.put(cap)
  end

  defp caps_from_slice(slice) do
    case Map.get(slice, :caps) do
      %MapSet{} = caps -> MapSet.to_list(caps)
      caps when is_list(caps) -> caps
      _ -> []
    end
  end

  defp caps_from_slice_checked(slice) do
    case Map.fetch(slice, :caps) do
      {:ok, %MapSet{} = caps} -> {:ok, MapSet.to_list(caps)}
      {:ok, caps} when is_list(caps) -> {:ok, caps}
      :error -> {:ok, []}
      {:ok, _invalid} -> {:error, :invalid_identity_caps}
    end
  end

  defp verified_checked(caps, uri) do
    verified = caps |> verified_set(uri) |> MapSet.to_list()

    if Enum.any?(verified, &current_self_license?(&1, uri)),
      do: {:ok, verified},
      else: {:ok, []}
  rescue
    error -> {:error, {:cap_verification_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:cap_verification_failed, kind, reason}}
  end

  defp current_self_license?(%Capability{} = cap, uri) do
    Capability.action_of(cap) == :self_license and
      Ezagent.Cap.Authority.verify_against_current(cap, uri, uri)
  end

  defp current_self_license?(_cap, _uri), do: false

  defp user_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  defp user_uri?(_uri), do: false

  defp parse_uri(%URI{} = uri), do: Ezagent.URI.instance(uri)
  defp parse_uri(uri) when is_binary(uri), do: uri |> Ezagent.URI.new!() |> Ezagent.URI.instance()

  defp normalize_dispatch_result(:ok), do: :ok
  defp normalize_dispatch_result({:ok, _result}), do: :ok
  defp normalize_dispatch_result({:error, _reason} = error), do: error
  defp normalize_dispatch_result(other), do: {:error, {:unexpected_persist_result, other}}
end
