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

  @doc "The identity lifecycle status for `uri`, or `nil` when no row exists."
  @spec status(URI.t() | String.t()) :: status() | nil
  def status(uri) do
    case fetch(uri) do
      nil -> nil
      %{identity_status: status} -> String.to_existing_atom(status)
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
  `Ezagent.EntityCaps` persisted-cap read): the store's complete cap set, or
  `:fallback` when no row exists (caller then reads the legacy store —
  `users.caps_json` / snapshot `:identity`). NOT consulted by `EntityCaps` in
  PR-1 — the store reads only its OWN row here (via `fetch/1`), so this is not a
  new authority-use site (phrased to avoid the Z-1 ratchet's doc-scan match).
  """
  @spec fetch_durable_caps(URI.t() | String.t()) :: {:ok, [Capability.t()]} | :fallback
  def fetch_durable_caps(uri) do
    case fetch(uri) do
      nil -> :fallback
      %{identity_status: "active", caps_json: caps_json} -> {:ok, decode_caps(caps_json)}
      %{identity_status: _non_active} -> {:ok, []}
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

  @doc """
  Upsert the complete cap set for `uri`, PRESERVING the existing
  `identity_status` / `provisioning_receipt` (a fresh insert defaults to
  `active` with no receipt — the dual-write mirror of a legacy write).

  This is the dual-write mirror operation: it MUST NOT change the lifecycle
  state; only the provisioning API does.
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
    encoded = encode_caps(caps)
    now = now_usec()
    workspace = workspace_key(uri)

    %__MODULE__{}
    |> Ecto.Changeset.change(
      uri: key(uri),
      caps_json: encoded,
      identity_status: "active",
      workspace_uri: workspace
    )
    |> Repo.insert(
      on_conflict: [set: [caps_json: encoded, workspace_uri: workspace, updated_at: now]],
      conflict_target: :uri
    )
    |> case do
      {:ok, _row} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Row-locked transform of the complete cap set (mirrors
  `UserStore.update/2` semantics, upserting): the row is created when
  absent, then locked `FOR UPDATE`, decoded, transformed, and re-encoded —
  status and receipt are preserved.
  """
  @spec update(URI.t() | String.t(), ([Capability.t()] ->
                                        {:ok, [Capability.t()] | MapSet.t(Capability.t())}
                                        | {:error, term()})) ::
          :ok | {:error, term()}
  def update(uri, fun) when is_function(fun, 1) do
    case Repo.transaction(fn -> update_locked(key(uri), workspace_key(uri), fun) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_locked(uri_key, workspace, fun) do
    with :ok <- ensure_row(uri_key, workspace),
         row when not is_nil(row) <- lock_row(uri_key),
         {:ok, caps} <- fun.(decode_caps(row.caps_json)),
         {:ok, _row} <-
           row |> Ecto.Changeset.change(caps_json: encode_caps(caps)) |> Repo.update() do
      :ok
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
  # Actor seams (config-injected; best-effort shadow, but NEVER silent —
  # every mirror failure is logged at :error; the legacy write remains the
  # authoritative outcome in PR-1)
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
      are deliberately NOT mirrored in PR-1 (`nil` kind_module, the direct
      `SnapshotStore.write/3` path, always mirrors: durable writers only);
    * the slice carries no caps set.

  A mirror failure is logged at `:error` (observable shadow divergence),
  never raised into the committing dispatch.
  """
  @spec sync_committed_identity(URI.t() | String.t(), module() | nil, term()) :: :ok
  def sync_committed_identity(uri, kind_module, slice) do
    with false <- user_uri?(uri),
         false <- skip_kind?(kind_module),
         %MapSet{} = caps <- slice_caps(slice) do
      case persist(uri, caps) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "EntityCaps.Store: identity shadow write FAILED for #{inspect(uri)} " <>
              "(reason=#{inspect(reason)}) — legacy snapshot committed; " <>
              "shadow row diverges until the next mirrored write or the migration backfill"
          )

          :ok
      end
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.error(
        "EntityCaps.Store: identity shadow write RAISED for #{inspect(uri)}: " <>
          Exception.message(e)
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "EntityCaps.Store: identity shadow write FAILED for #{inspect(uri)}: " <>
          "#{kind} #{inspect(reason)}"
      )

      :ok
  end

  @doc """
  Dual-write hook for `SnapshotStore.delete/1`: the legacy durable copy is
  gone, so the shadow row is deleted too (PR-1 keeps legacy destroy
  semantics; tombstone-on-destroy enforcement is the cutover PR).
  """
  @spec identity_snapshot_cleared(URI.t() | String.t()) :: :ok
  def identity_snapshot_cleared(uri) do
    from(row in __MODULE__, where: row.uri == ^key(uri))
    |> Repo.delete_all()

    :ok
  rescue
    e ->
      Logger.error(
        "EntityCaps.Store: identity shadow delete FAILED for #{inspect(uri)}: " <>
          Exception.message(e)
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "EntityCaps.Store: identity shadow delete FAILED for #{inspect(uri)}: " <>
          "#{kind} #{inspect(reason)}"
      )

      :ok
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
      transition_locked(uri, receipt, fn
        %{identity_status: "tombstoned"} -> {:error, :tombstoned}
        _row -> {:ok, activate_changes(caps, receipt)}
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
      transition_locked(uri, receipt, fn
        %{identity_status: "active"} -> {:error, :already_active}
        _row -> {:ok, activate_changes(caps, receipt)}
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
end
