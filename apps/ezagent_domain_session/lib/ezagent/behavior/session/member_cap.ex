defmodule Ezagent.ActionSet.Session.MemberCap do
  @moduledoc false
  #
  # Membership-cap unification A1.2 (spec R1.3 / R2.1) — the at-join universal
  # member-cap machinery, extracted VERBATIM from
  # `Ezagent.ActionSet.Session.Membership` (a cohesive slice that pushed
  # `membership.ex` over the 1000-LOC arch gate; sibling of
  # `Ezagent.ActionSet.Session.Reconcile`). These functions run in the SAME
  # Session Kind GenServer process whether defined here or in `Membership`; the
  # grant/revoke DISPATCH they issue is the identical cross-Kind async router
  # call. The member-cap is the universal base tier (§7): EVERY member (user,
  # agent, anon) that clears the `role_name` preflight is granted
  # `cap(:session, Session, :receive, S)` into its OWN `:identity` slice.

  require Logger

  alias Ezagent.Session.InternalReads

  @doc "Capture the durable message floor for a membership grant intent."
  @spec capture_join_cursor(URI.t(), map()) :: {non_neg_integer(), term()}
  def capture_join_cursor(%URI{} = member_uri, ctx) do
    cursors = ctx[:read].(:join_cursors, %{})

    cursor =
      Map.get_lazy(cursors, member_uri, fn ->
        InternalReads.current_message_sequence(ctx[:self_uri])
      end)

    {cursor, {:set, :join_cursors, Map.put(cursors, member_uri, cursor)}}
  end

  @doc """
  Grant the universal member-cap into the joining member's OWN `:identity`
  slice (A1.2). Returns `true` iff THIS call actually committed the grant.
  """
  # Best-effort + idempotent (§7): a skip-already-held (EXACT member-cap identity
  # via `holds_member_cap_exact?/3` — NOT the broad `matches?/2`, so a member
  # holding only a wildcard cap STILL gets the concrete member-cap; codex HIGH)
  # returns `false` (this call granted nothing → compensation must NOT revoke a
  # pre-existing cap); a `{:error}` grant is logged + telemetry'd and returns
  # `false` (A1 is behavior-preserving — a failed member-cap grant NEVER newly
  # fails a join; the §16-risk-#4 fail-closed shift is deferred to A2/lead).
  # `granted_by` = the session OWNER (read from `ctx`, never a self-call),
  # ownerless → the #154 admin granter.
  @spec grant_at_join(URI.t(), map()) :: boolean()
  def grant_at_join(%URI{} = member_uri, ctx) do
    session_uri = ctx[:self_uri]
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)
    held = member_snapshot_caps(member_uri)

    if holds_member_cap_exact?(held, session_uri, workspace_uri) do
      false
    else
      cap = member_cap(session_uri, workspace_uri)
      granter = grant_granter(ctx)

      # `:async` is REQUIRED here — EMPIRICALLY VERIFIED (codex MED, A1). This
      # runs inside the Session Kind's `handle_join`, and granting a
      # session-instance cap re-enters THIS session Kind during grant
      # ROUTING/dispatch, so a `:sync` call self-deadlocks: flipping to `:sync`
      # hangs the session-creation join path (`SessionCreator` →
      # `join_session_members` → `handle_join`) into a 5s `GenServer.call`
      # timeout. (The rule-branch AUTHORIZATION alone is not the re-entry — it
      # clears via `rule_cap_bounded?/1` — but the router still resolves the
      # instance owner.) The cast defers that resolution to after `handle_join`
      # returns (session free). The cap lands eventually (idempotent + reconcile
      # backstop), which is exactly A1's additive model.
      #
      # CONSEQUENCE (codex MED — DEFERRED, NOT fixed in A1): `:async` returns
      # `:ok` once the cast is BUFFERED, so `:ok` does NOT prove the grant
      # committed — the confirmed grant that would make test 23's
      # compensating-revoke fully verifiable needs the grant taken OFF the
      # `handle_join` path (an A2 grant-path rework; §16 risk-4 fail-closed
      # shift). A1 keeps the additive best-effort cast.
      result =
        with :ok <- Ezagent.Identity.TargetAuthority.ensure(granter, session_uri) do
          Ezagent.Identity.Grant.grant_cap_via_router(
            member_uri,
            cap,
            grant_authorization(granter),
            :async
          )
        end

      case result do
        :ok ->
          true

        :error ->
          log_grant_failure(member_uri, session_uri, :target_authority_unavailable)
          false

        {:error, reason} ->
          log_grant_failure(member_uri, session_uri, reason)
          false
      end
    end
  end

  @doc false
  @spec grant_for_reownership(URI.t(), URI.t()) :: :ok | {:error, term()}
  def grant_for_reownership(%URI{} = session_uri, %URI{} = new_owner) do
    grant_guaranteed(session_uri, new_owner)
  end

  @doc """
  Synchronously grant the session owner the born-signed tier-1 membership cap.

  This runs before the owner is mounted into the roster, outside the Session
  Kind's join handler, so creation cannot expose an owner whose structural URI
  bypasses membership generation checks.
  """
  @spec grant_owner_at_creation(URI.t(), URI.t()) :: :ok | {:error, term()}
  def grant_owner_at_creation(%URI{} = session_uri, %URI{} = owner) do
    grant_guaranteed(session_uri, owner)
  end

  defp grant_guaranteed(session_uri, principal) do
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)
    cap = member_cap(session_uri, workspace_uri)

    with :ok <- Ezagent.Identity.TargetAuthority.ensure(principal, session_uri),
         :ok <-
           Ezagent.Identity.Grant.issue_and_absorb_cap(
             principal,
             cap,
             grant_authorization(principal)
           ) do
      :ok
    end
  end

  defp log_grant_failure(member_uri, session_uri, reason) do
    Logger.warning(
      "Session.MemberCap.grant_at_join: member-cap grant failed for " <>
        "member=#{URI.to_string(member_uri)} on session=" <>
        "#{URI.to_string(session_uri)}: #{inspect(reason)} " <>
        "(best-effort in A1; reconcile_after_load/2 + the migration are the backstops)."
    )

    :telemetry.execute(
      [:ezagent, :session, :member_cap, :failed],
      %{count: 1},
      %{session_uri: session_uri, member_uri: member_uri, reason: reason}
    )
  end

  @doc """
  De-escalating compensation revoke of the just-granted member-cap (R1.3 step 4).
  """
  # Needs no authz (revoke is de-escalating); best-effort — a failed compensation
  # is logged and left to `reconcile_after_load/2` as the backstop.
  @spec revoke_at_join(URI.t(), map()) :: :ok
  def revoke_at_join(%URI{} = member_uri, ctx) do
    session_uri = ctx[:self_uri]
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)
    cap = member_cap(session_uri, workspace_uri)

    # `:async` for the same self-deadlock reason as the grant (the revoke of a
    # session-instance cap re-enters the Session Kind). Enqueued FIFO after the
    # grant cast, so the pair settles to "no member-cap".
    case Ezagent.Identity.Grant.revoke_cap_via_router(
           member_uri,
           cap,
           grant_authorization(ctx),
           :async
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Session.MemberCap.revoke_at_join: compensation revoke FAILED for " <>
            "member=#{URI.to_string(member_uri)} on session=" <>
            "#{URI.to_string(session_uri)}: #{inspect(reason)} " <>
            "(reconcile_after_load/2 evicts the orphaned projection/cap on next activate)."
        )

        :ok
    end
  end

  @doc """
  SYNCHRONOUS, CHECKED revoke of the member-cap on LEAVE / REMOVE (A2.4, spec
  R3.1). Returns `revoke_cap_via_router`'s `:ok | {:error, reason}`.

  Unlike `revoke_at_join/2` (the `:async` at-join COMPENSATION, which must not
  self-deadlock while `handle_join` is still resolving a materializing member),
  this runs on the LEAVE/REMOVE path where the member is ESTABLISHED + live, so a
  `:sync` revoke from inside the Session Kind returns cleanly (EMPIRICALLY
  VERIFIED — a sync `revoke_cap_via_router` from `handle_remove_participant` on an
  established member does NOT deadlock; the at-join deadlock is
  materialization-confined). The caller decides abort-safety: REMOVE treats a
  `{:error, _}` as ABORT (leave the member fully intact); LEAVE treats it as
  best-effort (log; reconcile heals).
  """
  @spec revoke_membership(URI.t(), map()) :: :ok | {:error, term()}
  def revoke_membership(%URI{} = member_uri, ctx) do
    session_uri = ctx[:self_uri]
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)
    cap = member_cap(session_uri, workspace_uri)

    Ezagent.Identity.Grant.revoke_cap_via_router(
      member_uri,
      cap,
      grant_authorization(ctx),
      :sync
    )
  end

  defp grant_authorization(%URI{} = owner) do
    admin = Ezagent.Entity.User.admin_uri()

    if Ezagent.URI.stable_key(owner) == Ezagent.URI.stable_key(admin),
      do: {:admin, owner},
      else: {:held_by, owner}
  end

  defp grant_authorization(ctx) when is_map(ctx) do
    ctx
    |> grant_granter()
    |> grant_authorization()
  end

  defp grant_granter(ctx) when is_map(ctx) do
    ctx[:read].(:owner_uri, nil) || Ezagent.Entity.User.admin_uri()
  end

  @doc """
  LEAVE revoke wrapper (A2.4 / R3.1) — best-effort: a revoke failure is logged
  (the member is de-escalating ITSELF and reconcile evicts any residue) and `:ok`
  is returned so the self-leave still drops the roster.
  """
  @spec revoke_member_cap_best_effort(URI.t(), map()) :: :ok
  def revoke_member_cap_best_effort(%URI{} = member_uri, ctx) do
    case revoke_membership(member_uri, ctx) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Session.MemberCap.leave: member-cap revoke failed for " <>
            "member=#{URI.to_string(member_uri)} on session=" <>
            "#{URI.to_string(ctx[:self_uri])}: #{inspect(reason)} " <>
            "(best-effort on self-leave; reconcile_after_load/2 evicts residue)."
        )

        :ok
    end
  end

  @doc """
  REMOVE revoke wrapper (A2.4 / R3.1) — CHECKED / abort-safe: a genuine revoke
  failure on a LIVE member ABORTS the removal (`{:error, _}` → the member is left
  FULLY INTACT — a loud error, never a silent partial). Placed by the caller AFTER
  every rejecting check (teardown authority + routing prune) has passed, so a
  rejected removal never reaches it and cap + roster stay intact (preserves test
  11). A NOT-LIVE member (`:no_such_actor` / `:not_ready`) has no live cap to
  revoke, so the removal PROCEEDS (mirrors the teardown's idempotent handling;
  reconcile/migration are the backstop for any persisted snapshot cap).
  """
  @spec revoke_member_cap_checked(URI.t(), map()) :: :ok | {:error, term()}
  def revoke_member_cap_checked(%URI{} = member_uri, ctx) do
    case revoke_membership(member_uri, ctx) do
      :ok ->
        :ok

      {:error, reason} when reason in [:no_such_actor, :not_ready] ->
        Logger.warning(
          "Session.MemberCap.remove_participant: member-cap revoke skipped for " <>
            "member=#{URI.to_string(member_uri)} on session=" <>
            "#{URI.to_string(ctx[:self_uri])}: #{inspect(reason)} (member not live; no " <>
            "live cap to revoke; removal proceeds, reconcile/migration backstop)."
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "Session.MemberCap.remove_participant: member-cap revoke FAILED for " <>
            "member=#{URI.to_string(member_uri)} on session=" <>
            "#{URI.to_string(ctx[:self_uri])}: #{inspect(reason)} — ABORTING the " <>
            "removal (member left fully intact; let-it-crash, no silent partial)."
        )

        {:error, {:member_cap_revoke_failed, reason}}
    end
  end

  @doc """
  Normalize a held-caps collection (list / `MapSet` / scalar) to a plain list.
  """
  @spec caps_to_list(term()) :: [term()]
  def caps_to_list(caps) do
    cond do
      is_list(caps) -> caps
      is_struct(caps, MapSet) -> MapSet.to_list(caps)
      true -> List.wrap(caps)
    end
  end

  # NON-BLOCKING idempotency source for the at-join grant: the member's PERSISTED
  # `:identity` caps read straight from `EntityCaps.load_persisted/1` (a
  # single indexed `Repo.get`, NO cross-Kind call). This is REQUIRED because
  # `grant_at_join/2` runs INSIDE the Session Kind's `handle_join`: the live cap
  # readers (the `Identity` list-caps-for reader `await_ready`s + `:call`s the
  # member Kind; `Kind.get_slice/2` `:call`s it) would STALL the Session Kind on
  # a not-yet-ready member (e.g. a worker mid-materialization) → cascade timeouts.
  # The snapshot may lag an in-flight async grant by the `:on_change` window; a
  # race just re-grants (`handle_grant_cap` dedups by `identity_key`, never
  # duplicates). A member with no snapshot yet (brand-new) reads `[]` → grants.
  @spec member_snapshot_caps(URI.t()) :: [Ezagent.Capability.t()]
  defp member_snapshot_caps(%URI{} = member_uri) do
    case Ezagent.EntityCaps.load_persisted(member_uri) do
      caps when is_list(caps) -> caps
      _missing_or_unavailable -> []
    end
  rescue
    _ -> []
  end

  # The universal member-cap constructor (A1.1): `cap(:session, Session,
  # :receive, S, ws)`. The behavior is the MODULE ref (invariant #2), not an
  # atom; arg order per `capability.ex:144-155`.
  @spec member_cap(URI.t(), URI.t()) :: Ezagent.Capability.t()
  defp member_cap(%URI{} = session_uri, %URI{} = workspace_uri) do
    Ezagent.Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      :receive,
      session_uri,
      workspace_uri
    )
  end

  # EXACT member-cap idempotency for the AT-JOIN grant (codex HIGH). True iff
  # `held` already contains THIS concrete member-cap `cap(:session, Session,
  # :receive, S)` by 5-tuple `identity_key/1` equality. Distinct from
  # `Membership.already_authorized?/5` (which uses the BROAD `matches?/2` —
  # correct for the `:join`/participation tiers, where admin's wildcard
  # legitimately dedups a re-grant): a broad `:any` cap does NOT satisfy the
  # member-cap need, so a member holding only a wildcard STILL gets the concrete
  # cap granted (which A2 authorizes receive on). Mirrors the migration's
  # `holds_member_cap_exact?/2`.
  @spec holds_member_cap_exact?([term()], URI.t(), URI.t()) :: boolean()
  defp holds_member_cap_exact?(held, %URI{} = session_uri, %URI{} = workspace_uri) do
    target_key = Ezagent.Capability.identity_key(member_cap(session_uri, workspace_uri))

    held
    |> caps_to_list()
    |> Enum.any?(fn
      %Ezagent.Capability{} = cap -> Ezagent.Capability.identity_key(cap) == target_key
      _ -> false
    end)
  end
end
