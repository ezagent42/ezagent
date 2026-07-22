defmodule Ezagent.ActionSet.Session.Reconcile do
  @moduledoc false
  #
  # Membership-cap unification A1.3 (spec §4.4) — the steady-state backstop that
  # SEEDS/HEALS the `:members` delivery projection from the authoritative
  # member-cap holder set on every `activate/2` (Kind (re)start).
  #
  # ## Roster ⟂ authz (R1.1)
  #
  # The `:members` projection is DELIVERY TARGETING only and staleness-tolerant;
  # the authority is the recipient's actually-held member-cap (A2). This reconcile
  # converges the projection toward the caps ("caps win", invariant #20) so a
  # cap-only drift (a member granted the cap but missing from the projection) is
  # HEALED — the member re-appears as a delivery target.
  #
  # ## M-8 cutover — exact cap-holder projection
  #
  # The member-cap migration and gate run before this eviction mode lands. Receive
  # and read already authorize from the held cap, so a roster-only entry has no
  # authority and is pure stale targeting data. Reconcile therefore returns
  # EXACTLY the enumerated cap holders: it preserves metadata for persisted
  # holders, adds missing holders offline, and evicts every non-holder.
  #
  # ## Bounded, no global scan, delivery NEVER calls it (§4.4)
  #
  #   1. `ws = workspace_of(S)` (O(1)).
  #   2. candidates = `InternalReads.users_in_workspace(ws)` (ordinary + anon)
  #      ∪ `InternalReads.agents_in_workspace(ws)` (agent + worker URIs backed by
  #      the Agent Kind). The raw enumeration primitives are reached only through
  #      the InternalReads gateway — read-plane §3.4.
  #   3. per candidate: read LIVE caps (`read_entity_caps/1`), apply the K4
  #      `granted_by_entity?/1` provenance filter BEFORE the EXACT-identity test
  #      (`identity_key/1` equality, NOT `matches?/2` — see `member_cap_holder?/3`)
  #      for the concrete member-cap over S.
  #   4. matching set = the reconciled projection.
  #
  # ## Error handling (§13) — NEVER crash `activate/2`
  #
  # Each candidate's cap-read is rescued: a raising candidate is logged
  # (`:warning`) and treated as a non-holder (fail-closed for targeting). The
  # whole scan is additionally rescued so a candidate-enumeration failure returns
  # the persisted projection unchanged rather than crashing the Kind boot; that
  # fallback grants no authority because act-time gates still read held caps.

  require Logger

  alias Ezagent.Session.InternalReads

  @doc """
  Reconcile `persisted_members` against the authoritative member-cap holder set
  for `session_uri`. Returns exactly the cap holders as the `:members`
  projection map. Never raises — a whole-scan failure returns
  `persisted_members` unchanged.
  """
  @spec reconcile_after_load(URI.t(), map()) :: map()
  def reconcile_after_load(%URI{} = session_uri, persisted_members)
      when is_map(persisted_members) do
    ws = Ezagent.Capability.workspace_of(session_uri)

    ws
    |> candidate_uris()
    |> Enum.filter(fn uri -> member_cap_holder?(uri, session_uri, ws) end)
    |> Map.new(fn holder ->
      # Preserve non-authority roster metadata only for a proven holder. A
      # healed cap-only member is offline until activation rebuilds monitors.
      {holder, Map.get(persisted_members, holder, %{online: false})}
    end)
  rescue
    error ->
      Logger.warning(
        "Session.Reconcile.reconcile_after_load/2: candidate scan failed for " <>
          "#{URI.to_string(session_uri)}: #{inspect(error.__struct__)} — keeping the " <>
          "persisted projection unchanged (fail-safe toward existing membership)."
      )

      persisted_members
  end

  # `users_in_workspace/1` includes anon-user rows; `agents_in_workspace/1`
  # scans snapshots whose Kind is Agent and therefore includes both `:agent` and
  # `:worker` principal URI types. Keep both categories explicit so adding a new
  # principal type cannot silently narrow the floor.
  defp candidate_uris(%URI{} = ws) do
    users = ws |> InternalReads.users_in_workspace() |> Enum.map(& &1.uri)
    anon_users = Enum.filter(users, &anon_user_uri?/1)
    regular_users = users -- anon_users
    agents = InternalReads.agents_in_workspace(ws)
    workers = Enum.filter(agents, &Ezagent.URI.type?(&1, :worker))
    regular_agents = agents -- workers
    Enum.uniq(regular_users ++ anon_users ++ regular_agents ++ workers)
  end

  defp anon_user_uri?(%URI{} = uri) do
    Ezagent.URI.type?(uri, :user) and
      match?({:ok, "anon-" <> _}, Ezagent.URI.name(uri))
  end

  # True iff `candidate` HOLDS the EXACT member-cap over `session_uri` — LIVE
  # caps, K4 provenance-filtered BEFORE the identity test. Rescued per-candidate
  # so a raising read is treated as "not a holder" and never crashes
  # `activate/2`.
  #
  # EXACT identity, NOT `matches?/2` (codex BLOCKER): the projection must be
  # SEEDED only from the concrete member-cap `cap(:session, Session, :receive,
  # S)`. `matches?/2`'s ASYMMETRIC wildcard semantics let a HELD `:any` cap
  # (admin genesis is an all-`:any` cap) satisfy the concrete `:receive` need —
  # which would re-add admin (and every broad-cap holder) into `:members` of
  # EVERY session on reload, silently CHANGING live membership (A1 delivery +
  # socialware still key off `:members`) and violating A1's additive contract.
  # So we compare the 5-tuple `identity_key/1` for EXACT equality — the same
  # exact-identity approach the migration's `holds_member_cap_exact?/2` uses.
  @spec member_cap_holder?(URI.t(), URI.t(), URI.t()) :: boolean()
  def member_cap_holder?(%URI{} = candidate, %URI{} = session_uri, %URI{} = ws) do
    target_key = Ezagent.Capability.identity_key(member_cap(session_uri, ws))

    candidate
    |> Ezagent.EntityCaps.load()
    |> Enum.filter(&Ezagent.Capability.granted_by_entity?/1)
    |> Enum.any?(fn cap -> Ezagent.Capability.identity_key(cap) == target_key end)
  rescue
    error ->
      Logger.warning(
        "Session.Reconcile.member_cap_holder?/3: cap read failed for candidate " <>
          "#{URI.to_string(candidate)}: #{inspect(error.__struct__)} — treated as " <>
          "non-holder (fail-closed targeting)."
      )

      false
  end

  # The universal member-cap constructor: `cap(:session, Session, :receive, S,
  # ws)`. Identical shape to `Membership.member_cap/2` and the migration's
  # `member_cap/2` — the ONE concrete cap whose `identity_key/1` seeds `:members`.
  defp member_cap(%URI{} = session_uri, %URI{} = ws) do
    Ezagent.Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      :receive,
      session_uri,
      ws
    )
  end
end
