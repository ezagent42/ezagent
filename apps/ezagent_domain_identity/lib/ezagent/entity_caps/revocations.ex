defmodule Ezagent.EntityCaps.Revocations do
  @moduledoc """
  ② P2(c) — the MONOTONE per-cap revocation tombstone ledger (codex
  adversarial review must-fix #3).

  Deleting the current rows is not enough to make a revoke durable: a stale
  LIVE holder keeps the cap in memory and any intervening whole-Kind snapshot
  write serializes that stale identity slice back into the durable planes
  (the snapshot binary, and — for non-users — the dual-written identity-caps
  Store + grantee index), so the next cold boot resurrects the revoked cap.

  This ledger records `"(holder_uri, cap identity) revoked at T"` durably,
  recorded by `Ezagent.EntityCaps.revoke_persisted/2` BEFORE the plane
  deletes commit (a tombstone-first failure aborts the revoke; the partial
  state after a later failure is always fail-safe — toward denial, never
  toward resurrection). Rows are insert-only and never deleted.

  ## The fence rule

  A candidate artifact is TOMBSTONED iff a row exists for its holder +
  cap identity AND the artifact's `granted_at` is at or before the row's
  `revoked_at` watermark. The watermark is what keeps the fence monotone
  without banning re-grants: `Ezagent.Cap.issue/3` re-stamps `granted_at`
  on every genuine grant, so an artifact issued AFTER the revoke carries a
  strictly later `granted_at` and passes; the pre-revoke artifact (the one a
  stale writer still holds) is blocked forever. A non-`DateTime`
  `granted_at` (`:compile_time` declarative shape) covered by a tombstone is
  blocked (fail-closed) — issued artifacts always carry a `DateTime`.

  The cap identity is `Capability.identity_key/1` with URI axes
  canonicalized to strings (generation- and provenance-independent) —
  exactly `Capability.revoke/2`'s match semantics, so a revoke argument that
  lacks the artifact's `key_id`/signature still fences the held artifact.

  ## Checked on every resurrection path

    * `Ezagent.ActionSet.Identity.activate/2` — the invariant-20 union
      (snapshot-restored caps ∪ `users.caps_json`) filters tombstoned
      artifacts before they reach the live slice or the re-persisted union.
    * `Ezagent.EntityCaps.Store` — every write boundary (`persist/2`,
      `update/2`, `backfill/2`, `provision/4`, `reprovision/4`) filters
      tombstoned artifacts inside the write transaction, so a stale
      whole-Kind snapshot write cannot re-add one to the Store or the
      reverse grantee index (which re-derives from the filtered set in the
      same transaction).

  Read-side DB failures raise (fail-loud, the
  `hydrate_recipe_binding` precedent): a fence that silently fails open is
  a resurrection vector, a fence that silently fails closed is a silent
  authority loss — the caller retries the boot/write instead.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Ezagent.Capability
  alias EzagentCore.Repo

  @primary_key false
  schema "cap_revocations" do
    field(:holder_uri, :string)
    field(:cap_digest, :string)
    field(:workspace_uri, :string)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Record the monotone tombstone `(holder, cap identity) → revoked_at`.

  Idempotent: a repeated revoke of the same cap advances the watermark via
  `GREATEST` (a re-grant between two revokes makes the second watermark
  strictly later; concurrent duplicate revokes cannot move it backwards).
  Returns `:ok` or `{:error, reason}` — the revoke aborts fail-closed on an
  error (no tombstone, no deletes).
  """
  @spec record(URI.t() | String.t(), Capability.t(), DateTime.t()) :: :ok | {:error, term()}
  def record(uri, %Capability{} = cap, revoked_at \\ DateTime.utc_now()) do
    holder = key(uri)

    # Upsert advancing the watermark MONOTONELY — the query form of
    # `on_conflict` (the keyword form cannot carry SQL fragments):
    # `revoked_at = GREATEST(existing, new)`, so a stale retry can never move
    # the fence backwards.
    on_conflict =
      from(row in __MODULE__,
        update: [set: [revoked_at: fragment("GREATEST(?, ?)", row.revoked_at, ^revoked_at)]]
      )

    %__MODULE__{}
    |> Ecto.Changeset.change(
      holder_uri: holder,
      cap_digest: digest(cap),
      workspace_uri: workspace_key(uri),
      revoked_at: revoked_at
    )
    |> Repo.insert(
      on_conflict: on_conflict,
      conflict_target: [:holder_uri, :cap_digest]
    )
    |> case do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, {:revocation_tombstone_write_failed, reason}}
    end
  rescue
    error -> {:error, {:revocation_tombstone_write_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:revocation_tombstone_write_failed, {kind, reason}}}
  end

  @doc """
  Whether `cap` is tombstoned for `uri` (a tombstone exists for its cap
  identity and the artifact's `granted_at` is at or before the watermark).
  Raises on a ledger read error (fail-loud — see moduledoc).
  """
  @spec tombstoned?(URI.t() | String.t(), Capability.t()) :: boolean()
  def tombstoned?(uri, %Capability{} = cap) do
    case watermarks(uri)[digest(cap)] do
      nil -> false
      revoked_at -> artifact_precedes?(cap, revoked_at)
    end
  end

  @doc """
  Drop every tombstoned artifact from `caps` for `uri`. One indexed ledger
  read per call; raises on a read error (fail-loud — see moduledoc).
  """
  @spec filter(URI.t() | String.t(), Enumerable.t()) :: [Capability.t()]
  def filter(uri, caps) do
    caps_list = Enum.to_list(caps)

    case watermarks(uri) do
      empty when map_size(empty) == 0 ->
        caps_list

      marks ->
        Enum.reject(caps_list, fn
          %Capability{} = cap ->
            case marks[digest(cap)] do
              nil -> false
              revoked_at -> artifact_precedes?(cap, revoked_at)
            end

          _other ->
            false
        end)
    end
  end

  @doc false
  @spec digest(Capability.t()) :: String.t()
  def digest(%Capability{} = cap) do
    cap
    |> Capability.identity_key()
    |> Tuple.to_list()
    |> Enum.map(fn
      %URI{} = uri -> URI.to_string(uri)
      other -> other
    end)
    |> List.to_tuple()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&"cap-id-v1:#{&1}")
  end

  # holder_uri → %{cap_digest => revoked_at} for one holder. Raises on a DB
  # error — callers are boot/write boundaries that must retry, never guess.
  defp watermarks(uri) do
    from(row in __MODULE__,
      where: row.holder_uri == ^key(uri),
      select: {row.cap_digest, row.revoked_at}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp artifact_precedes?(%Capability{granted_at: %DateTime{} = granted_at}, revoked_at),
    do: DateTime.compare(granted_at, revoked_at) != :gt

  # Fail-closed: a tombstone-covered artifact without a real grant timestamp
  # (a `:compile_time` declarative shape) is blocked — a genuine post-revoke
  # re-grant is always re-stamped by `Cap.issue/3` and never lands here.
  defp artifact_precedes?(%Capability{}, _revoked_at), do: true

  # The fence keys its rows by the exact same holder/workspace
  # canonicalization as the identity-caps Store — the fence must address the
  # same durable identity, so the implementation is shared (never forked).
  defp key(uri), do: Ezagent.EntityCaps.Store.key(uri)
  defp workspace_key(uri), do: Ezagent.EntityCaps.Store.workspace_key(uri)
end
