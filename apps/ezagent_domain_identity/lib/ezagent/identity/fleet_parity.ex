defmodule Ezagent.Identity.FleetParity do
  @moduledoc """
  #189 PR-2 D2 (codex spec-review F2) — the fleet-completion barrier.

  A verifiable predicate answering: *is `Ezagent.IdentityCaps.Store` a complete,
  parity-correct mirror of the LEGACY self-license set for every live durable
  principal?* PR-3's atomic read-cutover is GATED on this returning complete.

  It enumerates the CLOSED durable-holder population from the LEGACY source
  (never from the store — an empty store must report incomplete, never "done")
  and requires BIDIRECTIONAL parity:

    * **forward** (legacy → store) — every durable holder that presents a
      CURRENT-valid self-license has an `active` store row with a matching cap
      set; every durable holder whose legacy license is NOT current-valid has
      a durable `revoked_unprovisioned` / `tombstoned` row (NEVER absent,
      NEVER `active`);
    * **backward** (store → legacy) — every `active` store row is backed by a
      current-valid legacy durable holder; a phantom store-only `active` row
      is rejected.

  ## Explicit per-class treatment (the exact holes codex F2 names)

    * **Ephemeral holders** (`ExternalMirrorWorker`) are EXEMPT: they have no
      durable legacy source in PR-2, so they are absent from `users` /
      `kind_snapshots` by design. Their durable identity + parity requirement
      belong to PR-3. Declared closed in `Ezagent.Identity.AuthenticatedHolders`
      so this exemption is explicit, not an accidental "100% while a real
      principal is absent" gap.
    * **The canonical admin** (`entity://system/user/admin`) is EXEMPT from the
      "license-invalid ⇒ must be revoked" forward rule: its accepted fresh-boot
      contract permits an empty `users.caps_json` while the live slice supplies
      currency.

  ## TOCTOU / rolling-deploy (codex F2 caveat)

  This is a POINT-IN-TIME predicate. `CI can test the predicate; it cannot
  prove production fleet state.` Legacy writes commit first and the shadow
  mirror later (best-effort), so a `check/0` result is only authoritative under
  **write-quiescence**: PR-3's cutover MUST run the backfill, then this barrier,
  under a quiesced identity-write window (no concurrent grant/revoke/provision),
  and cut reads over inside that same fence. This module documents + verifies
  the predicate; the deployment fence is an operational precondition PR-3 owns.

  > **PR-3 PRECONDITION (codex impl-review finding 3, do not drop).** A
  > `complete: true` result is NOT a live guarantee on its own — the barrier has
  > no epoch/quiescence fence of its own and a concurrent legacy/store write can
  > invalidate the result the instant after it returns. PR-3's atomic read
  > cutover MUST therefore assert this barrier INSIDE a write-quiescence/epoch
  > fence (backfill → barrier → flip reads, all under the same fence). The
  > barrier proves parity at a point in time; the fence makes that point the
  > cutover instant.
  """

  alias Ezagent.IdentityCaps.Store
  alias Ezagent.Identity.AuthenticatedHolders

  @type discrepancy :: {atom(), String.t()}
  @type result :: %{
          complete: boolean(),
          checked: non_neg_integer(),
          discrepancies: [discrepancy()]
        }

  @doc """
  Run the barrier. `complete: true` iff the store is a parity-correct mirror of
  the legacy durable-holder self-license set (both directions).
  """
  @spec check() :: result()
  def check do
    {holders, read_errors} = legacy_durable_holders()
    legacy_uris = MapSet.new(holders, fn h -> h.uri_str end)

    forward = Enum.flat_map(holders, &forward_discrepancies/1)
    backward = backward_discrepancies(legacy_uris)

    # A legacy source that could not be READ (decode failure, vanished row) is
    # surfaced as a discrepancy, NEVER silently omitted (codex impl-review
    # finding 3): a durable principal must not disappear from BOTH sides of the
    # comparison and let the barrier claim complete.
    read_error_discrepancies = Enum.map(read_errors, fn {uri_str, _reason} -> {:legacy_read_error, uri_str} end)

    discrepancies = forward ++ backward ++ read_error_discrepancies ++ session_identity_gaps()

    %{
      complete: discrepancies == [],
      checked: length(holders),
      discrepancies: discrepancies
    }
  end

  # ------------------------------------------------------------------
  # Session principal gaps (#189 PR-3 FIX 4)
  # ------------------------------------------------------------------

  # Every REAL (non-marker-only) Session must be a principal. A pre-carrier
  # Session persisted its `:kind_base` WITHOUT SelfLicense and so has no
  # `:identity` self-license and NO store row — an un-migrated principal, which
  # the barrier MUST flag so the cutover refuses until the Session self-license
  # migration (FIX 4) has run. The gap is scoped to REAL sessions with NO store
  # row: a DESTROYED (marker-only) session legitimately has no identity (codex's
  # "every session" is over-broad — a buried session must not wedge the barrier),
  # and an already-processed session carries an `active` (migrated) or
  # `revoked_unprovisioned`/`tombstoned` (adopted) row, so neither is flagged.
  defp session_identity_gaps do
    Ezagent.Ecto.KindSnapshot.list_all()
    |> Enum.filter(&(&1.kind_type == "session"))
    |> Enum.flat_map(&session_gap/1)
  end

  defp session_gap(row) do
    case Ezagent.Ecto.KindSnapshot.decode_state(row) do
      {:ok, state} ->
        uri = to_uri(row.uri)

        if real_session_row?(row, state) and is_nil(Store.status(uri)) do
          [{:session_missing_identity, store_uri_str(uri)}]
        else
          []
        end

      _ ->
        # Undecodable rows are surfaced by the general read-error path.
        []
    end
  end

  # Marker-only (destroyed: `ever_created` + empty state) is NOT a real session.
  defp real_session_row?(%{ever_created: true}, state) when map_size(state) == 0, do: false

  defp real_session_row?(_row, state) when is_map(state) do
    Enum.any?(
      [:session, :publisher, :chat, :turns, :surface, :external_mirror],
      &Map.has_key?(state, &1)
    )
  end

  @doc "Convenience boolean form of `check/0`."
  @spec complete?() :: boolean()
  def complete?, do: check().complete

  # ------------------------------------------------------------------
  # Forward (legacy → store)
  # ------------------------------------------------------------------

  defp forward_discrepancies(%{uri: uri, uri_str: uri_str, caps: caps, licensed?: licensed?}) do
    status = Store.status(uri)

    cond do
      # The canonical-admin fresh-boot exception is NARROW (codex impl-review
      # finding 3): it exempts a license-invalid admin ONLY from the
      # "must-be-revoked" rule (its empty `caps_json` is legitimate while the
      # live slice supplies currency). It does NOT exempt a DIVERGENT admin row:
      # a license-invalid admin with an `:active` store row is a genuine
      # `:stale_active` divergence and is still caught.
      not licensed? and canonical_admin?(uri) ->
        case status do
          :active -> [{:stale_active, uri_str}]
          _ -> []
        end

      not licensed? ->
        case status do
          s when s in [:revoked_unprovisioned, :tombstoned] -> []
          nil -> [{:absent_license_invalid, uri_str}]
          :active -> [{:stale_active, uri_str}]
        end

      # A license-valid principal must be `active` with a matching cap set.
      licensed? ->
        case status do
          :active -> caps_parity(uri, uri_str, caps)
          nil -> [{:missing_active_row, uri_str}]
          _other -> [{:unexpected_non_active, uri_str}]
        end
    end
  end

  # Set parity by FULL SIGNED cap identity — not just the logical `identity_key`
  # 5-tuple (codex impl-review finding 3: `identity_key/1` excludes signature,
  # key-id and provenance, so a stale/tampered store artifact with the same
  # logical axes would pass). Compares the complete serialized cap (`to_map/1`:
  # kind/behavior/action/instance/workspace + signature + key_id + granted_by +
  # grantee_uri) MINUS `granted_at` — the only round-trip-fragile field (an
  # ISO8601 timestamp), excluded to avoid false mismatches while still catching
  # any signature / key-id / provenance divergence.
  defp caps_parity(uri, uri_str, legacy_caps) do
    if signed_identity_set(Store.load(uri)) == signed_identity_set(legacy_caps) do
      []
    else
      [{:caps_mismatch, uri_str}]
    end
  end

  # ------------------------------------------------------------------
  # Backward (store → legacy)
  # ------------------------------------------------------------------

  defp backward_discrepancies(legacy_uris) do
    Store.active_uris()
    |> Enum.reject(&MapSet.member?(legacy_uris, &1))
    |> Enum.map(&{:phantom_active, &1})
  end

  # ------------------------------------------------------------------
  # Legacy enumeration (the CLOSED durable-holder worklist)
  # ------------------------------------------------------------------

  # Returns `{holders, read_errors}`: the CLOSED durable-holder worklist plus the
  # legacy sources that could not be read (surfaced as discrepancies by `check/0`
  # — never silently dropped; codex impl-review finding 3).
  defp legacy_durable_holders do
    {snapshot_holders, read_errors} = legacy_snapshot_holders()
    {legacy_users() ++ snapshot_holders, read_errors}
  end

  defp legacy_users do
    Enum.map(Ezagent.Users.list_all(), fn user ->
      uri = to_uri(user.uri)
      caps = Map.get(user, :caps) || []
      holder(uri, caps)
    end)
  end

  # The store-MIRROR population: every non-user snapshot the shadow dual-write
  # is expected to mirror — i.e. every durable (snapshot-backed, non-ephemeral)
  # entity whose `:identity` slice carries caps. This is BROADER than the
  # authenticated-holder gate population: templates are `:non_holder` for the
  # PR-3 authz gate, yet they ARE snapshot-backed self-license carriers that
  # the store mirrors, so they belong in the PR-2 parity set (otherwise their
  # legitimate `active` rows would read as backward "phantoms"). Ephemeral
  # holders (per `AuthenticatedHolders`) are excluded — they are not
  # snapshot-backed and carry no durable legacy source (codex F2 exemption).
  # Returns `{holders, read_errors}`. A snapshot whose `:identity` slice cannot
  # be READ (decode failure, vanished row) becomes a `read_error` rather than a
  # silent skip — otherwise a durable principal disappears from the forward set
  # AND its `active` store row is untested, letting the barrier claim complete
  # (codex impl-review finding 3). A genuinely caps-less snapshot (no `:identity`
  # slice — a non-principal) is still a legitimate skip.
  defp legacy_snapshot_holders do
    Ezagent.Kind.list_durable_instances()
    # A user's durable source is `users.caps_json` (enumerated in
    # `legacy_users/0`), NEVER its snapshot — reject user snapshots so a user
    # is never double-counted.
    |> Enum.reject(fn {uri_str, _meta} -> user_uri?(uri_str) end)
    |> Enum.reject(fn {_uri_str, meta} -> ephemeral_holder_meta?(meta) end)
    |> Enum.reduce({[], []}, fn {uri_str, _meta}, {holders, errors} ->
      uri = to_uri(uri_str)

      case snapshot_identity_caps(uri) do
        {:ok, caps} -> {[holder(uri, caps) | holders], errors}
        :none -> {holders, errors}
        {:error, reason} -> {holders, [{store_uri_str(uri), reason} | errors]}
      end
    end)
  end

  defp user_uri?(uri) when is_binary(uri) do
    case Ezagent.URI.new!(uri) do
      %URI{scheme: "entity"} = parsed -> Ezagent.URI.type?(parsed, :user)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp ephemeral_holder_meta?(%{kind_type: kind_type}) when is_binary(kind_type) do
    AuthenticatedHolders.ephemeral_holder?(safe_atom(kind_type))
  end

  defp ephemeral_holder_meta?(_meta), do: false

  # `{:ok, caps}` when the durable `:identity` slice carries a caps set (the
  # entity IS store-mirrored); `:none` when the row read cleanly but carries no
  # `:identity` caps (a non-principal); `{:error, reason}` when the read itself
  # FAILED — a decode failure or a row that vanished mid-scan
  # (`read_durable/3` collapses both a decode `:error` and an absent row to
  # `{:error, :not_created}`) — which must be surfaced, never silently skipped
  # (codex impl-review finding 3).
  defp snapshot_identity_caps(uri) do
    case Ezagent.Kind.read_durable(uri, :identity) do
      {:ok, identity, _meta} when is_map(identity) ->
        if Map.has_key?(identity, :caps), do: {:ok, caps_from_slice(identity)}, else: :none

      {:ok, _non_caps_slice, _meta} ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp holder(uri, caps) do
    %{
      uri: uri,
      # Normalize to the store's key form so `uri_str` matches
      # `Store.active_uris/0` (which stores `instance |> to_string`) for the
      # backward phantom check.
      uri_str: store_uri_str(uri),
      caps: caps,
      licensed?: Store.has_current_self_license?(Enum.to_list(caps), uri)
    }
  end

  # The store's canonical URI-string form (`instance |> to_string`) — shared by
  # the holder projection and the read-error reporting so both align with
  # `Store.active_uris/0`. (This is the SAME expression `holder/2` used inline
  # pre-refactor; kept inline-equivalent to stay off the uri_query `_key` scan.)
  defp store_uri_str(uri), do: uri |> Ezagent.URI.instance() |> URI.to_string()

  defp to_uri(%URI{} = uri), do: uri
  defp to_uri(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp canonical_admin?(%URI{} = uri) do
    Ezagent.URI.stable_key(uri) == Ezagent.URI.stable_key(Ezagent.URI.user(:system, :admin))
  end

  # The FULL signed cap identity as a set — the complete serialized cap MINUS
  # the round-trip-fragile `granted_at` timestamp. Includes signature, key_id
  # and provenance, so a stale/tampered store artifact sharing only the logical
  # axes is caught (codex impl-review finding 3).
  defp signed_identity_set(caps) do
    MapSet.new(caps, fn cap ->
      cap |> Ezagent.Capability.to_map() |> Map.delete("granted_at")
    end)
  end

  defp caps_from_slice(slice) do
    case Map.get(slice, :caps) do
      %MapSet{} = caps -> MapSet.to_list(caps)
      caps when is_list(caps) -> caps
      _ -> []
    end
  end

  defp safe_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> :__unknown__
  end
end
