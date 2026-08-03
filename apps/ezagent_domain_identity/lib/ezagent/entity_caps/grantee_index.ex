defmodule Ezagent.EntityCaps.GranteeIndex do
  @moduledoc """
  Reverse cap index — "who currently holds a cap toward target T" (URI-share A2-2).

  A **derived, read-only projection** of the authoritative cap store. It is
  written from the ONE place a held-cap becomes durable — inside
  `Ezagent.EntityCaps.Store`'s write transaction (`persist_locked` /
  `update_locked` / `backfill_locked`), via `reindex_in_txn/2`. That is the sole
  downstream confluence of EVERY conferral path (grant, `initial_caps`, cold-load
  reconcile, backfill, activate, and the agent authoritative write
  `sync_committed_identity/3` → `persist`), so no writer is missed — and because
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
  non-grant arrival (initial_caps / backfill / reconcile / activate).

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
  alias Ezagent.EntityCaps.Store

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
  (`persist_locked`/`update_locked`/`backfill_locked`) — it opens NO transaction
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
      Enum.flat_map(caps, fn cap ->
        cap |> normalize_legacy_shape() |> row_attrs(grantee_key)
      end)

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
  @spec grantees_of(URI.t(), URI.t(), Enumerable.t(), module() | atom(), atom()) :: [URI.t()]
  def grantees_of(%URI{} = target, %URI{} = caller, caller_caps, behavior \\ :any, action \\ :any) do
    if Ezagent.Identity.Authority.manages?(caller, target, caller_caps) do
      query_grantees(target, behavior, action)
    else
      []
    end
  end

  @doc """
  PLATFORM-MECHANISM entry — the same reverse read WITHOUT the `manages?/3`
  human-administrator gate.

  Allen 2026-07-31: the caller of this arity is a MECHANISM computing a
  projection **inside its own domain, over a SINGLE named target** (e.g.
  `ActionSet.Session.Membership` deriving a session's member roster from the
  caps held toward that session) — a platform-mechanism declaration, not an
  external principal enumerating someone else's grantees. It therefore carries
  no user-level cap witness, and correspondingly must NEVER be reachable from a
  dispatch/transport path: the ENTITY must not read the cap table directly, only
  its owning mechanism may.

  `grantees_of/5` — the externally reachable arity — keeps `manages?/3`
  unchanged; do not "simplify" the two into one.

  The caller allowlist is frozen by
  `test/invariants/grantee_index_mechanism_entry_test.exs` — adding a caller is
  a deliberate, reviewed act.
  """
  @spec grantees_of_internal(URI.t(), module() | atom(), atom()) :: [URI.t()]
  def grantees_of_internal(%URI{} = target, behavior \\ :any, action \\ :any) do
    query_grantees(target, behavior, action)
  end

  defp query_grantees(%URI{} = target, behavior, action) do
    target_key = Ezagent.URI.stable_key(target)

    case active_key_id(target_key) do
      nil ->
        []

      active_key ->
        from(r in __MODULE__,
          where: r.target_uri == ^target_key and r.key_id == ^active_key,
          select: {r.grantee_uri, r.granted_by}
        )
        |> maybe_filter_behavior(behavior)
        |> maybe_filter_action(action)
        |> Repo.all()
        # K4 provenance — mirror `Capability.granted_by_entity?/1` (false ONLY
        # for a `system://` granter). The consumers of this index authorize on
        # ENTITY-granted caps; a system-granted row must not seed their
        # projection. Applied in-app so the predicate stays byte-identical to
        # the struct-level one instead of drifting into a SQL LIKE pattern.
        |> Enum.filter(&entity_granted?/1)
        |> Enum.map(fn {grantee_key, _granted_by} -> grantee_key end)
        |> Enum.uniq()
        # codex ④a: drop grantees whose OWN identity is no longer active
        # (offboarded/tombstoned) — filtered in-app against `Store.status/1`
        # (which normalizes the key), fail-closed (nil/revoked/tombstoned all
        # excluded), avoiding a store-key-vs-index-key format-match on a SQL join.
        |> Enum.filter(&grantee_active?/1)
        |> Enum.map(&Ezagent.URI.new!/1)
    end
  end

  defp entity_granted?({_grantee_key, nil}), do: true

  defp entity_granted?({_grantee_key, granted_by}) when is_binary(granted_by),
    do: not String.starts_with?(granted_by, "system://")

  defp entity_granted?(_), do: false

  defp grantee_active?(grantee_key), do: Store.status(grantee_key) == :active

  @doc """
  One-time backfill of the reverse index from the authoritative store (codex ①).
  Called by the create-table migration so existing grants appear immediately,
  not only after each grantee's next cap change. Idempotent — re-running replaces
  each grantee's rows.
  """
  @spec backfill_all() :: :ok
  def backfill_all do
    Enum.each(Store.active_uris(), fn grantee_uri ->
      caps = Store.load(grantee_uri)
      Repo.transaction(fn -> reindex_in_txn(grantee_uri, caps) end)
    end)

    :ok
  end

  defp maybe_filter_behavior(query, :any), do: query

  defp maybe_filter_behavior(query, behavior) do
    b = behavior_string(behavior)
    from(r in query, where: r.behavior == ^b)
  end

  # Action-dimension filter (#1655 P2). The column has always been written
  # (`row_attrs/2`) but was never read, so a behavior-only reverse query returned
  # EVERY action toward the target — e.g. an invited-but-never-joined principal
  # holding only `cap(:session, Session, :join, S)` came back indistinguishable
  # from a `:receive` member. Consumers that key off ONE concrete action must
  # pass it; `:any` preserves the previous behavior-only semantics.
  defp maybe_filter_action(query, :any), do: query

  defp maybe_filter_action(query, action) do
    a = to_string(action)
    from(r in query, where: r.action == ^a)
  end

  # Single, consistent read of the target's active-authority generation.
  defp active_key_id(target_key) do
    case KindCapAuthority.active(target_key) do
      %{key_id: key_id} -> key_id
      _ -> nil
    end
  end

  # #189 canary rehearsal catch #3 — legacy-shape tolerance at the reindex
  # boundary. A pre-#1399 durable `:identity` slice snapshotted a `%Capability{}`
  # before the cap-signing trio (`signature` / `key_id` / `grantee_uri`,
  # 2026-07-14); `binary_to_term` reconstructs it as a struct-shaped map that
  # MATCHES `%Capability{}` (struct matching only checks `:__struct__`) yet LACKS
  # those keys. `row_attrs/2`'s strict `cap.key_id` read then raised
  # `(KeyError) key :key_id not found`, and because this reindex runs INSIDE the
  # authoritative Store write transaction with NO rescue (by design — it commits
  # atomically with the cap row), the whole cutover backfill rolled back and the
  # epoch refused to activate. Re-project every cap onto a fresh defstruct HERE —
  # the sole confluence of every reindex caller (persist / update / backfill /
  # activate / backfill_all) — so `row_attrs` and every strict field read only
  # ever sees a complete struct: the trio's missing keys fill with their `nil`
  # defaults. This is the SAME shared helper (`Capability.Normalize.fill_defaults/1`)
  # `Capability.to_map/1` and the `Jason.Encoder` impl route through (#213), so
  # the serialize and index paths cannot drift on legacy tolerance; it is
  # idempotent on already-complete structs (no double-normalize harm). Fail-closed
  # holds: it NEVER fabricates a signature or widens an authorization axis — a
  # legacy cap normalizes to an UNSIGNED cap (`key_id: nil`), whose nil `key_id`
  # folds cleanly into `row_id/5` and is naturally EXCLUDED by the `active_key_id`
  # read filter (an unsigned legacy cap is not an active holder). A non-struct
  # input is passed through untouched to the `_non_concrete` `row_attrs` sink.
  defp normalize_legacy_shape(%Capability{} = cap), do: Capability.Normalize.fill_defaults(cap)
  defp normalize_legacy_shape(other), do: other

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
