defmodule Ezagent.ActionSet.Session.MemberCap do
  @moduledoc false
  #
  # Membership-cap unification A1.2 (spec R1.3 / R2.1) — the at-join universal
  # member-cap machinery, extracted VERBATIM from
  # `Ezagent.ActionSet.Session.Membership` (a cohesive slice that pushed
  # `membership.ex` over the 1000-LOC arch gate; sibling of
  # `Ezagent.ActionSet.Session.Reconcile`). These functions run in the SAME
  # Session Kind GenServer process whether defined here or in `Membership`; the
  # target-authority ISSUE and durable absorb they perform are shared for every
  # caller. The member-cap is the universal base tier (§7): EVERY member (user,
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
  Enqueue the universal member-cap grant into the joining member's OWN
  `:identity` slice. Returns whether the exact cap already existed, the grant
  was enqueued, or the enqueue failed synchronously. On either successful
  branch, consumes the concrete tier-0 `:join` artifact: DROP is rejoinable,
  but only after a fresh owner/invite/public-policy grant.
  """
  # Idempotency uses the EXACT member-cap identity (NOT broad `matches?/2`, so a
  # wildcard holder still receives the concrete member cap). An existing exact
  # artifact is re-absorbed through the durable delivery outbox: storage dedups
  # it, while the after-commit hook re-triggers a missing projection.
  # `granted_by` = the session OWNER (read from `ctx`, never a self-call),
  # ownerless → the #154 admin granter.
  @spec grant_at_join(URI.t(), map()) :: :already_held | :enqueued | {:error, term()}
  def grant_at_join(%URI{} = member_uri, ctx) do
    session_uri = ctx[:self_uri]
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)

    case Ezagent.EntityCaps.effective_caps_persisted(member_uri) do
      {:ok, caps} ->
        grant_from_effective_caps(caps, member_uri, session_uri, workspace_uri, ctx)

      {:error, _reason} = error ->
        error
    end
  end

  defp grant_from_effective_caps(held, member_uri, session_uri, workspace_uri, ctx) do
    case exact_member_cap(held, session_uri, workspace_uri) do
      %Ezagent.Capability{} = existing ->
        with :ok <- Ezagent.Identity.absorb_cap(member_uri, existing),
             :ok <- consume_join_entitlement(member_uri, ctx) do
          :already_held
        else
          {:error, reason} -> {:error, reason}
        end

      nil ->
        cap = member_cap(session_uri, workspace_uri)
        granter = grant_granter(ctx)

        # Issuance runs in the Session Kind's current-target authority
        # compartment, avoiding a self-call. Delivery uses the existing
        # `absorb_cap` outbox, so a cold principal needs no registry PID here;
        # the artifact drains on activation and its Identity hook self-adds.
        result =
          with :ok <- Ezagent.Identity.TargetAuthority.ensure(granter, session_uri),
               {:ok, artifact} <-
                 Ezagent.Identity.Grant.issue_cap(
                   member_uri,
                   cap,
                   grant_authorization(granter)
                 ),
               :ok <- Ezagent.Identity.absorb_cap(member_uri, artifact),
               :ok <- consume_join_entitlement(member_uri, ctx) do
            :ok
          end

        case result do
          :ok ->
            :enqueued

          :error ->
            log_grant_failure(member_uri, session_uri, :target_authority_unavailable)
            {:error, :target_authority_unavailable}

          {:error, reason} ->
            log_grant_failure(member_uri, session_uri, reason)
            {:error, reason}
        end
    end
  end

  # M-10: a concrete tier-0 join grant is single-use. A successful join consumes
  # it after the tier-1 absorb has been durably enqueued. DROP therefore remains
  # fully rejoinable, but only after an owner/invite/public policy grants a NEW
  # tier-0 artifact; stale navigation cannot replay yesterday's grant to re-mint
  # a revoked membership cap. Async is required inside the Session Kind callback
  # (see Identity.Grant.revoke_cap_via_router/4's self-deadlock contract).
  defp consume_join_entitlement(%URI{} = member_uri, ctx) do
    session_uri = ctx[:self_uri]

    join_cap =
      Ezagent.Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :join,
        session_uri,
        Ezagent.Capability.workspace_of(session_uri)
      )

    case Ezagent.Identity.Grant.revoke_cap_via_router(
           member_uri,
           join_cap,
           grant_authorization(ctx),
           :async
         ) do
      :ok -> :ok
      # A cold/offline principal cannot hold a live join artifact; its tier-1
      # absorb is already durable in the delivery outbox. Treat the idempotent
      # consume as complete and let a future join require a newly deliverable
      # tier-0 grant.
      {:error, reason} when reason in [:no_such_actor, :not_ready] -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec grant_agent_participation_at_join(URI.t(), map()) :: :ok | {:error, term()}
  def grant_agent_participation_at_join(%URI{} = member_uri, ctx) when is_map(ctx) do
    if Ezagent.URI.type?(member_uri, :agent) do
      session_uri = ctx[:self_uri]
      workspace_uri = Ezagent.Capability.workspace_of(session_uri)
      granter = grant_granter(ctx)

      Enum.reduce_while([:send, :leave, :attach], :ok, fn action, :ok ->
        cap =
          Ezagent.Capability.cap(
            :session,
            Ezagent.ActionSet.Session,
            action,
            session_uri,
            workspace_uri
          )

        result =
          with :ok <- Ezagent.Identity.TargetAuthority.ensure(granter, session_uri),
               {:ok, artifact} <-
                 Ezagent.Identity.Grant.issue_cap(
                   member_uri,
                   cap,
                   grant_authorization(granter)
                 ),
               :ok <- Ezagent.Identity.absorb_cap(member_uri, artifact) do
            :ok
          end

        case result do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      :ok
    end
  end

  def grant_agent_participation_at_join(_, _), do: :ok

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
        "#{URI.to_string(session_uri)}: #{inspect(reason)} (join fails closed)."
    )

    :telemetry.execute(
      [:ezagent, :session, :member_cap, :failed],
      %{count: 1},
      %{session_uri: session_uri, member_uri: member_uri, reason: reason}
    )
  end

  @doc """
  SYNCHRONOUS, CHECKED revoke of the member-cap on LEAVE / REMOVE (A2.4, spec
  R3.1). Returns `revoke_cap_via_router`'s `:ok | {:error, reason}`.

  This runs on the LEAVE/REMOVE path where the member is ESTABLISHED + live, so a
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
    authorization = grant_authorization(ctx)

    case Ezagent.Identity.Grant.revoke_cap_via_router(
           member_uri,
           member_cap(session_uri, workspace_uri),
           authorization,
           :sync
         ) do
      :ok ->
        revoke_participation_tier(member_uri, session_uri, workspace_uri, authorization)
        :ok

      {:error, _reason} = error ->
        # ABORT path (REMOVE contract): leave the member FULLY intact — do not
        # strip the participation tier when the authoritative member-cap revoke
        # did not land.
        error
    end
  end

  # #1665 — REVOCATION COMPLETENESS.
  #
  # At join a member receives FOUR caps, not one: the authoritative member-cap
  # `:receive` plus the participation tier (`Membership.chat_action_pairs/0` =
  # `:send`/`:leave`/`:attach` on `Ezagent.ActionSet.Session`, and
  # `Membership.publisher_action_pairs/0` = `:subscribe_from` on
  # `Ezagent.ActionSet.Publisher.SessionImpl`). Leave/remove used to revoke ONLY
  # `:receive`, so a departed member kept live write authority: `:send`/`:attach`
  # are NOT in `Cap.Verifier`'s `@non_cap_actions` allowlist and
  # `Session.handle_send/2` performs no membership re-check beyond the cap — i.e.
  # write-after-leave.
  #
  # Best-effort by design: the caller's abort contract keys off the member-cap
  # result above (already returned `:ok` when we get here). A partial failure
  # here logs + emits telemetry and leaves the remaining caps in the PRE-FIX
  # state — never worse than before — and `reconcile` plus the next revoke pass
  # heal it. Revoking a cap the member never held (e.g. the chat tier of an
  # unconfirmed user) is a no-op.
  defp revoke_participation_tier(member_uri, session_uri, workspace_uri, authorization) do
    pairs =
      Ezagent.ActionSet.Session.Membership.chat_action_pairs() ++
        Ezagent.ActionSet.Session.Membership.publisher_action_pairs()

    Enum.each(pairs, fn {behavior, action} ->
      cap =
        Ezagent.Capability.cap(:session, behavior, action, session_uri, workspace_uri)

      case Ezagent.Identity.Grant.revoke_cap_via_router(
             member_uri,
             cap,
             authorization,
             :sync
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Session.MemberCap.revoke_participation_tier/4: revoke failed for member=" <>
              "#{URI.to_string(member_uri)} session=#{URI.to_string(session_uri)} " <>
              "action=#{inspect(action)}: #{inspect(reason)} (best-effort; the cap " <>
              "remains as it did pre-#1665 and is retried on the next revoke pass)."
          )

          :telemetry.execute(
            [:ezagent, :session, :participation_revoke, :failed],
            %{count: 1},
            %{
              session_uri: session_uri,
              member_uri: member_uri,
              behavior: behavior,
              action: action,
              reason: reason
            }
          )

          :ok
      end
    end)
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
  11). A NOT-LIVE member (`:no_such_actor` / `:not_ready` / `:failed`) has no live cap to
  revoke, so the removal PROCEEDS (mirrors the teardown's idempotent handling;
  reconcile/migration are the backstop for any persisted snapshot cap).
  """
  @spec revoke_member_cap_checked(URI.t(), map()) :: :ok | {:error, term()}
  def revoke_member_cap_checked(%URI{} = member_uri, ctx) do
    case revoke_membership(member_uri, ctx) do
      :ok ->
        :ok

      {:error, reason} when reason in [:no_such_actor, :not_ready, :failed] ->
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
  defp exact_member_cap(held, %URI{} = session_uri, %URI{} = workspace_uri) do
    target_key = Ezagent.Capability.identity_key(member_cap(session_uri, workspace_uri))

    held
    |> caps_to_list()
    |> Enum.find(fn
      %Ezagent.Capability{} = cap -> Ezagent.Capability.identity_key(cap) == target_key
      _ -> false
    end)
  end
end
