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
  # ## A1 is additive / behavior-preserving — UNION, not replace
  #
  # In A1 delivery still uses the ephemeral mint keyed on `:members`, so EVICTING
  # a roster-only entry (present in the projection, no held cap) would silently
  # stop that member receiving under the OLD path — a behavior change. So A1
  # reconcile UNIONS: it keeps every persisted member AND adds any cap-holder
  # missing from the projection. The eviction half ("roster-only ⇒ drop") becomes
  # correct+safe in A2 (once receive reads the held cap, a roster-only member is
  # already receive-denied, so dropping it is pure cleanup) and is deferred there.
  #
  # ## Bounded, no global scan, delivery NEVER calls it (§4.4)
  #
  #   1. `ws = workspace_of(S)` (O(1)).
  #   2. candidates = `Users.list_in_workspace(ws)` ∪ `Entity.Agent.list_in_workspace(ws)`.
  #   3. per candidate: read LIVE caps (`read_entity_caps/1`), apply the K4
  #      `granted_by_entity?/1` provenance filter BEFORE the EXACT-identity test
  #      (`identity_key/1` equality, NOT `matches?/2` — see `member_cap_holder?/3`)
  #      for the concrete member-cap over S.
  #   4. matching set ∪ persisted projection = the reconciled projection.
  #
  # ## Error handling (§13) — NEVER crash `activate/2`
  #
  # Each candidate's cap-read is rescued: a raising candidate is logged
  # (`:warning`) and treated as a non-holder, so the persisted projection entry
  # (if any) survives via the union — fail-safe toward existing membership. The
  # whole scan is additionally rescued so a candidate-enumeration failure returns
  # the persisted projection unchanged rather than crashing the Kind boot.

  require Logger

  @doc """
  Reconcile `persisted_members` against the authoritative member-cap holder set
  for `session_uri`. Returns the UNION (persisted ∪ cap-holders) as the
  `:members` projection map. Never raises — a scan failure returns
  `persisted_members` unchanged.
  """
  @spec reconcile_after_load(URI.t(), map()) :: map()
  def reconcile_after_load(%URI{} = session_uri, persisted_members)
      when is_map(persisted_members) do
    ws = Ezagent.Capability.workspace_of(session_uri)

    ws
    |> candidate_uris()
    |> Enum.filter(fn uri -> member_cap_holder?(uri, session_uri, ws) end)
    |> Enum.reduce(persisted_members, fn holder, acc ->
      if Map.has_key?(acc, holder) do
        acc
      else
        # A healed cap-only member: not currently monitored (offline until it
        # (re)connects); `activate/2` rebuilds monitors only for live members.
        Map.put(acc, holder, %{online: false})
      end
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

  # candidates = users ∪ agents in the workspace (both kinds carry member-caps).
  defp candidate_uris(%URI{} = ws) do
    users = ws |> Ezagent.Users.list_in_workspace() |> Enum.map(& &1.uri)
    agents = Ezagent.Entity.Agent.list_in_workspace(ws)
    Enum.uniq(users ++ agents)
  end

  # True iff `candidate` HOLDS the EXACT member-cap over `session_uri` — LIVE
  # caps, K4 provenance-filtered BEFORE the identity test. Rescued per-candidate
  # so a raising read is treated as "not a holder" (the persisted entry survives
  # via the union) and never crashes `activate/2`.
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
          "non-holder (persisted projection entry preserved)."
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
