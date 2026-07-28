defmodule Ezagent.Identity.FleetParity do
  @moduledoc """
  #189 PR-2 D2 (codex spec-review F2) — the fleet-completion barrier.

  A verifiable predicate answering: *is `Ezagent.EntityCaps.Store` a complete,
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
  """

  alias Ezagent.EntityCaps.Store
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
    legacy = legacy_durable_holders()
    legacy_uris = MapSet.new(legacy, fn h -> h.uri_str end)

    forward = Enum.flat_map(legacy, &forward_discrepancies/1)
    backward = backward_discrepancies(legacy_uris)

    discrepancies = forward ++ backward

    %{
      complete: discrepancies == [],
      checked: length(legacy),
      discrepancies: discrepancies
    }
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
      # A license-invalid principal is EITHER the canonical-admin fresh-boot
      # exception (exempt) OR must carry a durable non-active row.
      not licensed? and canonical_admin?(uri) ->
        []

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

  # Set parity by cap identity-key between the legacy caps and the store's
  # active caps (codex F2: "caps match legacy (byte/set parity)").
  defp caps_parity(uri, uri_str, legacy_caps) do
    if identity_key_set(Store.load(uri)) == identity_key_set(legacy_caps) do
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

  defp legacy_durable_holders do
    legacy_users() ++ legacy_snapshot_holders()
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
  defp legacy_snapshot_holders do
    Ezagent.Kind.list_durable_instances()
    # A user's durable source is `users.caps_json` (enumerated in
    # `legacy_users/0`), NEVER its snapshot — reject user snapshots so a user
    # is never double-counted.
    |> Enum.reject(fn {uri_str, _meta} -> user_uri?(uri_str) end)
    |> Enum.reject(fn {_uri_str, meta} -> ephemeral_holder_meta?(meta) end)
    |> Enum.flat_map(fn {uri_str, _meta} ->
      uri = to_uri(uri_str)

      case snapshot_identity_caps(uri) do
        {:ok, caps} -> [holder(uri, caps)]
        :none -> []
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
  # entity IS store-mirrored), `:none` when there is no `:identity` slice (not
  # a principal for the identity-caps store).
  defp snapshot_identity_caps(uri) do
    case Ezagent.Kind.read_durable(uri, :identity) do
      {:ok, identity, _meta} when is_map(identity) ->
        if Map.has_key?(identity, :caps), do: {:ok, caps_from_slice(identity)}, else: :none

      _ ->
        :none
    end
  end

  defp holder(uri, caps) do
    %{
      uri: uri,
      # Normalize to the store's key form so `uri_str` matches
      # `Store.active_uris/0` (which stores `instance |> to_string`) for the
      # backward phantom check.
      uri_str: uri |> Ezagent.URI.instance() |> URI.to_string(),
      caps: caps,
      licensed?: Store.has_current_self_license?(Enum.to_list(caps), uri)
    }
  end

  defp to_uri(%URI{} = uri), do: uri
  defp to_uri(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp canonical_admin?(%URI{} = uri) do
    Ezagent.URI.stable_key(uri) == Ezagent.URI.stable_key(Ezagent.URI.user(:system, :admin))
  end

  defp identity_key_set(caps) do
    caps
    |> Enum.map(&Ezagent.Capability.identity_key/1)
    |> MapSet.new()
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
