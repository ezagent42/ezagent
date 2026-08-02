defmodule Ezagent.IdentityCaps.GranteeIndex do
  @moduledoc """
  Reverse cap index — "who currently holds a cap toward target T" (URI-share A2-2).

  A **derived, read-only projection** of the authoritative cap store. It is
  written from the ONE place a held-cap becomes durable — inside
  `Ezagent.IdentityCaps.Store`'s write transaction (`persist_locked` /
  `update_locked` and activation paths), via `reindex_in_txn/2`. That is the sole
  downstream confluence of every conferral path (grant, initialization,
  cold-load reconcile, and activation), so no writer is missed — and because
  it runs IN the same transaction, the index commits ATOMICALLY with the cap row:
  a rolled-back commit never leaves the index over-reporting a cap that never
  durably landed. Direction is strictly cap → row, never row → key (re-minting
  from the index would be the second-truth-source trap the deleted
  `socialware_mounts` table was).

  Why the store WRITE (not `Cap.authorize` the check, nor `Cap.issue`/`Grant` the
  grant): in this cap-as-truth model, `Cap.authorize` reads the holder's caps
  FROM this same store, so deriving the reverse index from store writes makes
  "index has grantee G for T" ⟺ "authorize will accept G holding a cap toward T"
  — index and authz read share one truth source. The grant point would miss every
  non-grant arrival (initialization / reconcile / activation).

  Revocation needs no delete: each row stamps the `key_id` (generation) of the
  cap that produced it, and `grantees_of/4` filters to the target's CURRENT active
  authority `key_id` AND to grantees whose own identity is still `active` — so a
  target regenesis, or an offboarded/tombstoned grantee, drops out of reads
  automatically (the same fresh read the dispatch cap verifier applies).

  This is the reverse half of `Ezagent.Cap.Visibility.caps_toward/2` (A2-1) and
  the seam a session's `:members` roster becomes a projection of (A4-2).
  """
  use Ecto.Schema

  import Ecto.Query

  require Logger

  alias EzagentCore.Repo
  alias Ezagent.Capability
  alias Ezagent.Ecto.KindCapAuthority
  alias Ezagent.IdentityCaps.Store

  @primary_key {:id, :string, autogenerate: false}
  schema "cap_grantee_index" do
    field(:target_uri, :string)
    field(:grantee_uri, :string)
    field(:behavior, :string)
    field(:action, :string)
    field(:key_id, :string)
    field(:granted_by, :string)
    field(:workspace_uri, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Replace `grantee`'s reverse-index rows with the concrete-target caps in `caps`.

  **MUST be called from inside the authoritative `Store` write transaction**
  (`persist_locked` / `update_locked` / activation) — it opens NO transaction
  of its own, so it commits atomically with the cap-row write and rolls back with
  it. `caps` is the grantee's FULL new cap set (the store always persists the
  complete set), so a delete-all-by-grantee + re-insert is correct and never
  strands a workspace-partial view. Concrete-target caps only — `:any` /
  scope-tuple instances have no single target to key on. Best-effort ONLY at the
  row-shape level (a bad cap is skipped); it never raises, so a derived-index quirk
  cannot fail the authoritative cap write it rides.
  """
  @spec reindex_in_txn(URI.t() | String.t(), Enumerable.t()) :: :ok
  def reindex_in_txn(uri, caps) do
    grantee_key = grantee_key(uri)

    rows =
      Enum.flat_map(caps, &row_attrs(&1, grantee_key))

    Repo.delete_all(from(r in __MODULE__, where: r.grantee_uri == ^grantee_key))

    Enum.each(rows, fn attrs ->
      %__MODULE__{}
      |> Ecto.Changeset.change(attrs)
      # Fresh after delete-all, but stay collision-proof: `row_id` now folds
      # `key_id` in, so two caps differing only by generation no longer collide.
      |> Repo.insert!(on_conflict: :nothing, conflict_target: :id)
    end)

    :ok
  end

  @doc """
  Grantees who CURRENTLY hold a valid cap toward `target`, as authorized by the
  caller who PRESENTS `caller_caps`, optionally narrowed to a `behavior`.

  **Authorization is a presented, unforgeable witness (codex ②).** `caller_caps`
  is the caller's AUTHENTICATED held-cap set (from the dispatch ctx / self-license
  — signed, verified), NOT loaded from a caller URI. So a caller cannot enumerate
  a target's grantees by merely NAMING `user://system/admin`; they must actually
  present a cap that MANAGES the target (owner / admin / workspace-admin). Any
  other caller gets `[]` (fail-closed).

  Filters (single, consistent reads):

    * the target's CURRENT active-authority `key_id` (revoked/regenesis'd caps
      drop out); read once.
    * grantees whose OWN identity is still `active` (offboarded/tombstoned
      grantees drop out — codex ④a).

  Returns each distinct grantee once. Unknown target (no active authority) → `[]`.
  """
  @spec grantees_of(URI.t(), URI.t(), Enumerable.t(), module() | atom()) :: [URI.t()]
  def grantees_of(%URI{} = target, %URI{} = caller, caller_caps, behavior \\ :any) do
    target_key = Ezagent.URI.stable_key(target)
    active_key = active_key_id(target_key)

    cond do
      not Ezagent.Identity.Authority.manages?(caller, target, caller_caps) ->
        []

      active_key == nil ->
        []

      true ->
        from(r in __MODULE__,
          where: r.target_uri == ^target_key and r.key_id == ^active_key,
          select: r.grantee_uri
        )
        |> maybe_filter_behavior(behavior)
        |> Repo.all()
        |> Enum.uniq()
        # codex ④a: drop grantees whose OWN identity is no longer active
        # (offboarded/tombstoned) — filtered in-app against `Store.status/1`
        # (which normalizes the key), fail-closed (nil/revoked/tombstoned all
        # excluded), avoiding a store-key-vs-index-key format-match on a SQL join.
        |> Enum.filter(&grantee_active?/1)
        |> Enum.map(&Ezagent.URI.new!/1)
    end
  end

  defp grantee_active?(grantee_key), do: Store.status(grantee_key) == :active

  defp maybe_filter_behavior(query, :any), do: query

  defp maybe_filter_behavior(query, behavior) do
    b = behavior_string(behavior)
    from(r in query, where: r.behavior == ^b)
  end

  # Single, consistent read of the target's active-authority generation.
  defp active_key_id(target_key) do
    case KindCapAuthority.active(target_key) do
      %{key_id: key_id} -> key_id
      _ -> nil
    end
  end

  # Only concrete-target caps are indexed; wildcard (`:any` / scope-tuple)
  # instances have no single target to key on.
  defp row_attrs(%Capability{instance: %URI{} = instance} = cap, grantee_key) do
    target_key = Ezagent.URI.stable_key(instance)
    behavior = behavior_string(cap.behavior)
    action = to_string(cap.action)
    key_id = to_string_or_nil(cap.key_id)

    [
      %{
        # codex row-id: fold `key_id` in so two caps toward the same
        # (target, behavior, action) but different generations don't collide on
        # the natural key (which rolled back the whole reindex → stale index).
        id: row_id(target_key, grantee_key, behavior, action, key_id),
        target_uri: target_key,
        grantee_uri: grantee_key,
        behavior: behavior,
        action: action,
        key_id: cap.key_id,
        granted_by: to_string_or_nil(cap.granted_by),
        # codex ⑤ + per-tenant NOT NULL: derive the row's tenant from the CONCRETE
        # target instance, NOT `cap.workspace_uri` (which is `URI.t() | :any` — a
        # concrete-instance cap routinely carries `:any`, which was raising a
        # FunctionClauseError swallowed by the old rescue → silent stale index).
        # The target is always concrete here, so its workspace always resolves,
        # never NULL — and it is the correct tenant for a per-target reverse row.
        workspace_uri: target_workspace_string(instance)
      }
    ]
  end

  defp row_attrs(_non_concrete, _grantee_key), do: []

  defp row_id(target_key, grantee_key, behavior, action, key_id) do
    :crypto.hash(
      :sha256,
      Enum.join([target_key, grantee_key, behavior, action, key_id || ""], "/")
    )
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp behavior_string(behavior) when is_atom(behavior), do: to_string(behavior)
  defp behavior_string(behavior) when is_binary(behavior), do: behavior

  defp grantee_key(%URI{} = uri), do: Ezagent.URI.stable_key(uri)
  defp grantee_key(uri) when is_binary(uri), do: uri

  # The row tenant: the CONCRETE target instance's workspace. Always resolves to a
  # non-NULL string (a cross-cutting `system://` target lands in the `:any`
  # structural sink, stringified — the `Store.workspace_key` precedent), so the
  # per-tenant NOT-NULL invariant holds and `cap.workspace_uri: :any` never
  # reaches here.
  defp target_workspace_string(%URI{} = instance) do
    case Ezagent.URI.workspace_of(instance) do
      %URI{} = ws -> URI.to_string(ws)
      other -> to_string(other)
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(%URI{} = uri), do: URI.to_string(uri)
  defp to_string_or_nil(other), do: to_string(other)
end
