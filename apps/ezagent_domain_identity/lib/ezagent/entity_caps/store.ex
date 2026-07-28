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
      state was created by genuine provision/re-provision, not a spawn race.

  `kind_cap_authorities` is unchanged (signing keys + generation). This store
  holds caps + status + receipt.

  ## PR-1 contract (dual-write + dual-read; NOT yet authoritative)

    * Dual-WRITE: every cap mutation writes BOTH the legacy store
      (`users.caps_json` for users / the snapshot `:identity` slice for
      other durable entities) AND this store. The write points are
      `UserStore.update/2` (same transaction), the `Kind.Server`
      commit chokepoint, and `SnapshotStore.write/delete` — so this store
      mirrors each entity's LEGACY authoritative source exactly.
    * Dual-READ: durable reads (`EntityCaps.load_persisted/1`,
      `Kind.read_durable/3` for `:identity`) prefer this store and fall back
      to the legacy source when no row exists. Live-first reads are
      unchanged in PR-1.
    * Ephemeral/external-persistence Kinds are NOT mirrored in PR-1 (their
      identity durability arrives with the atomic cutover); users are
      mirrored via `users.caps_json` writes only.
    * `Authority.open(:existed)` empty-history failure, tombstone-on-destroy
      enforcement, and removing the legacy stores as authoritative are the
      LATER cutover PR — not here.

  The provisioning API (`provision/3`, `reprovision/3`,
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
    field :caps_json, :string
    field :identity_status, :string, default: "active"
    field :provisioning_receipt, :string

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

  @doc "Whether a store row exists for `uri` (the PR-1 existence signal)."
  @spec has_row?(URI.t() | String.t()) :: boolean()
  def has_row?(uri), do: not is_nil(fetch(uri))

  @doc """
  The addendum §4 existence signal for the CapBAC read classifier: a store
  row proves the URI is a KNOWN entity even when no durable snapshot row
  exists. USER URIs are excluded in PR-1 — their existence source remains
  `users` / snapshots (a `users.caps_json` mirror write must not reclassify
  a snapshot-less user from `:absent` to transient).
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
  callers that need dual-read fallback use `fetch_durable_caps/1`.
  """
  @spec load(URI.t() | String.t()) :: [Capability.t()]
  def load(uri) do
    case fetch(uri) do
      %{identity_status: "active", caps_json: caps_json} -> decode_caps(caps_json)
      _ -> []
    end
  end

  @doc """
  Dual-read entry point for `Ezagent.EntityCaps.load_persisted/1`: the
  store's complete cap set, or `:fallback` when no row exists (caller then
  reads the legacy store — `users.caps_json` / snapshot `:identity`).
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
  Dual-read entry point for the `Kind.read_durable/3` `:identity` projection
  (actor seam, config-injected): the synthesized `:identity` slice
  `%{caps: MapSet.t()}` plus `read_durable`-shaped meta, or `:fallback`.
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
  one query, returns only the URIs that have a store row.
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
  # Dual-write mirror (PR-1 additive writes — preserve status + receipt)
  # ====================================================================

  @doc """
  Upsert the complete cap set for `uri`, PRESERVING the existing
  `identity_status` / `provisioning_receipt` (a fresh insert defaults to
  `active` with no receipt — the dual-write mirror of a legacy write).

  This is the dual-write mirror operation: it MUST NOT change the lifecycle
  state; only the provisioning API does.
  """
  @spec persist(URI.t() | String.t(), [Capability.t()] | MapSet.t(Capability.t())) ::
          :ok | {:error, term()}
  def persist(uri, caps) when is_list(caps) or is_struct(caps, MapSet) do
    encoded = encode_caps(caps)
    now = now_usec()

    %__MODULE__{}
    |> Ecto.Changeset.change(uri: key(uri), caps_json: encoded, identity_status: "active")
    |> Repo.insert(
      on_conflict: [set: [caps_json: encoded, updated_at: now]],
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
    case Repo.transaction(fn -> update_locked(key(uri), fun) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_locked(uri_key, fun) do
    :ok = ensure_row(uri_key)
    row = Repo.one(from(r in __MODULE__, where: r.uri == ^uri_key, lock: "FOR UPDATE"))

    with {:ok, caps} <- fun.(decode_caps(row.caps_json)),
         {:ok, _row} <-
           row |> Ecto.Changeset.change(caps_json: encode_caps(caps)) |> Repo.update() do
      :ok
    end
  end

  defp ensure_row(uri_key) do
    %__MODULE__{}
    |> Ecto.Changeset.change(uri: uri_key)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :uri)
    |> case do
      {:ok, _row} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  # ====================================================================
  # Actor seams (config-injected; NEVER raise — the legacy store remains
  # authoritative in PR-1, so a mirror failure must not break a dispatch)
  # ====================================================================

  @doc """
  Dual-write hook for the snapshot commit / direct snapshot write paths.

  `slice` is the raw `:identity` slice (any shape: Lifecycle two-container,
  persisted single-key `%{state: _}`, or legacy flat). Skipped (returns
  `:ok` without writing) when:

    * `uri` is a USER — user rows mirror `users.caps_json` via
      `UserStore.update/2` instead (the legacy authoritative user source);
    * `kind_module` is `:ephemeral`/`:external` persistence — those Kinds
      are deliberately NOT mirrored in PR-1 (`nil` kind_module, the direct
      `SnapshotStore.write/3` path, always mirrors: durable writers only);
    * the slice carries no caps set.
  """
  @spec sync_committed_identity(URI.t() | String.t(), module() | nil, term()) :: :ok
  def sync_committed_identity(uri, kind_module, slice) do
    with false <- user_uri?(uri),
         false <- skip_kind?(kind_module),
         %MapSet{} = caps <- slice_caps(slice),
         :ok <- persist(uri, caps) do
      :ok
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.error(
        "EntityCaps.Store: identity mirror write failed for #{inspect(uri)}: " <>
          Exception.message(e)
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "EntityCaps.Store: identity mirror write failed for #{inspect(uri)}: " <>
          "#{kind} #{inspect(reason)}"
      )

      :ok
  end

  @doc """
  Dual-write hook for `SnapshotStore.delete/1`: the legacy durable copy is
  gone, so the mirror row is deleted too (PR-1 keeps legacy destroy
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
        "EntityCaps.Store: identity mirror delete failed for #{inspect(uri)}: " <>
          Exception.message(e)
      )

      :ok
  catch
    _, _ -> :ok
  end

  # ====================================================================
  # Provisioning API (additive in PR-1 — no runtime caller yet)
  # ====================================================================

  @doc """
  Genuine provision (the `:created`-with-receipt transition): activate
  `uri` with the complete cap set (incl. a freshly minted self-license) and
  the authenticated receipt. Idempotent re-activation of an `active` row;
  REJECTED when the URI is `tombstoned` (only `reprovision/3` passes that).
  """
  @spec provision(URI.t() | String.t(), [Capability.t()] | MapSet.t(Capability.t()),
          ProvisioningReceipt.t()
        ) :: :ok | {:error, term()}
  def provision(uri, caps, %ProvisioningReceipt{} = receipt) do
    with :ok <- require_receipt(receipt, uri, :provision) do
      transition_locked(uri, fn
        %{identity_status: "tombstoned"} -> {:error, :tombstoned}
        _row -> {:ok, activate_changes(caps, receipt)}
      end)
    end
  end

  @doc """
  Explicit re-provision (authenticated operator op): the ONLY transition out
  of `revoked_unprovisioned` / `tombstoned` — mints a new self-license
  (caller supplies the new complete cap set), activates, and records the
  fresh receipt.
  """
  @spec reprovision(URI.t() | String.t(), [Capability.t()] | MapSet.t(Capability.t()),
          ProvisioningReceipt.t()
        ) :: :ok | {:error, term()}
  def reprovision(uri, caps, %ProvisioningReceipt{} = receipt) do
    with :ok <- require_receipt(receipt, uri, :reprovision) do
      transition_locked(uri, fn
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
    transition_locked(uri, fn
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
    transition_locked(uri, fn
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

  defp require_receipt(receipt, uri, transition) do
    if ProvisioningReceipt.valid_for?(receipt, uri, transition) do
      :ok
    else
      {:error, :invalid_provisioning_receipt}
    end
  end

  # Row-locked status transition. `fun` inspects the locked row (which the
  # `ensure_row` upsert guarantees exists) and returns `{:ok, changes}` or
  # `{:error, reason}`.
  defp transition_locked(uri, fun) do
    uri_key = key(uri)

    case Repo.transaction(fn ->
           with :ok <- ensure_row(uri_key) do
             row =
               Repo.one(from(r in __MODULE__, where: r.uri == ^uri_key, lock: "FOR UPDATE"))

             case fun.(row) do
               {:ok, []} ->
                 :ok

               {:ok, changes} ->
                 case row |> Ecto.Changeset.change(changes) |> Repo.update() do
                   {:ok, _row} -> :ok
                   {:error, changeset} -> {:error, changeset}
                 end

               {:error, reason} ->
                 {:error, reason}
             end
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # ====================================================================
  # Internals
  # ====================================================================

  defp key(%URI{} = uri), do: uri |> Ezagent.URI.instance() |> URI.to_string()
  defp key(uri) when is_binary(uri), do: uri |> Ezagent.URI.new!() |> Ezagent.URI.instance() |> URI.to_string()

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
  defp slice_caps(%{state: state} = slice) when is_map(state) and map_size(slice) == 1, do: slice_caps(state)
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
