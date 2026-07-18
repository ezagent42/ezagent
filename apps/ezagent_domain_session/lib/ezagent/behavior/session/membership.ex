defmodule Ezagent.ActionSet.Session.Membership do
  @moduledoc false
  #
  # Join machinery extracted VERBATIM from `Ezagent.ActionSet.Session`
  # (PR-3R helper extraction). These functions run in the same Session
  # Kind GenServer process whether defined here or in `Behavior.Session` —
  # the effect lists they BUILD (`{:set, ...}` / `{:set_transient, ...}` /
  # the membership-broadcast `{:notify, ...}` effects) are emitted by the
  # `handle_join/2` callback in `Behavior.Session`, and the same-process
  # side-effects (`Process.monitor` / `Process.demonitor` / the owner-cap
  # `Ezagent.Notifications.notify`) are identical to
  # running in `Behavior.Session`.

  require Logger

  alias Ezagent.ActionSet.Session.{Delivery, MemberCap, Members}

  @doc """
  Add a member to the session — the `:join` handler body. Builds the
  `{:ok, result, [effect]}` tuple the `handle_join/2` callback returns.

  `source_module` is the `Behavior.Session` module reference used as the
  `:source` on join notifications (preserves the pre-extraction
  `__MODULE__` semantics).
  """
  @spec do_join(URI.t(), pid(), map(), map(), module()) ::
          {:ok, map(), [term()]} | {:error, term()}
  def do_join(%URI{} = member_uri, member_pid, ctx, facets, source_module) do
    members = ctx[:read].(:members, %{})

    # recipe-responsibility-split (2026-06-27, OQ-1) — `role_name` (the session
    # RESPONSIBILITY, axis B) is taken ONLY from the explicit join `facets` here;
    # it is NEVER derived from the member's agent RECIPE (axis A — the agent's
    # build-spec / `Ezagent.Agent.Recipe`, mirrored to `Ezagent.Agent.RecipeAttributes`).
    # DO NOT add a `role_name = Map.get(facets, :role_name) || recipe_name(...)`
    # default: that would re-create the very recipe⇄responsibility coupling the
    # split removed (a member with no declared responsibility silently inheriting
    # its recipe name as a routing label). A join that omits `:role_name` leaves
    # the member with NO `role_name` — `put_member_facets/2` skips the nil facet,
    # and the lazy instance-name path falls back to the source-TEMPLATE path
    # segment (`TemplateTeam.spawned_member_instance_name/4`), never the recipe.
    # The independence is locked by `recipe_responsibility_lockin_test.exs`.
    #
    # team-routing-unification §3.1 (spec §8 decision #2) — `role_name` is
    # UNIQUE PER SESSION. Reject a join that would assign a role_name already
    # held by a DIFFERENT member BEFORE any monitor side effect, so a rejected
    # join leaks no monitor. A member rejoining with its OWN role_name is fine.
    case Members.role_name_conflict(members, member_uri, Map.get(facets, :role_name)) do
      {:error, _} = err ->
        err

      :ok ->
        # Membership-cap unification A1.2 (spec R1.3 / R2.1 JOIN sequence —
        # grant-first, AFTER the zero-side-effect `role_name_conflict/3`
        # preflight, compensate on a post-grant failure). The member-cap is the
        # NEW universal base tier (§7): EVERY member (user, agent, anon) that
        # clears the preflight is granted `cap(:session, Session, :receive, S)`
        # into its OWN `:identity` slice, so receive/read AUTHORIZE on the held
        # cap in A2 (never a bearer token). A1 is additive/behavior-preserving —
        # the grant lands but delivery/receive still use the ephemeral mint.
        #
        # Placed here (in `do_join`, through the single `handle_join`
        # chokepoint) so it covers ALL member kinds uniformly — every add path
        # (World invite, orchestrator, materializer, anon admission, direct
        # `session.join`) funnels through here. Unlike `mount_participation_caps/2`
        # (the `Users.confirmed?/1` tier, kept caller-side for its Repo read) the
        # member-cap is UNCONDITIONAL, so it needs no Repo read in the Session
        # Kind — only the owner, read from `ctx` (never a self-call to
        # `Session.owner`). The cross-Kind grant DISPATCH to the member's identity
        # Kind is consistent with the existing at-join grant flow (spec §2.2) and
        # runs on the cold join path. The at-join member-cap machinery lives in
        # the sibling `Session.MemberCap` module.
        # Membership-cap unification Part C admission gate (spec §C.1 / R4) — the
        # ONE gate, at the COMMON member-cap grant seam reached by `handle_join/2`
        # from EVERY member-add entry path (World `invite_member/3`, orchestrator
        # `join_member`, materializer, direct `session.join`). Fire PENDING iff
        # `ctx.caller` is a real, non-system entity that is neither the member nor
        # a manager of it (`Authority.manages?/2`, resolved from the caller's
        # DURABLE identity caps by URI — NOT `ctx.caps`). A pending add grants NO
        # member-cap and does NOT mount into `:members`, so the pending member
        # holds no cap ⇒ receive is DENIED (R1.1) ⇒ the owner's credential is not
        # spent, until the member's owner approves (`:approve_admission`). All
        # non-add / manage-authorized / self / materializer mounts take the
        # existing grant+mount path unchanged.
        if admission_pending?(member_uri, ctx) do
          record_pending_admission(member_uri, ctx)
        else
          granted? = MemberCap.grant_at_join(member_uri, ctx)

          # Compensation (R1.3 step 4): a post-grant failure in `do_join_apply`
          # (monitor error, replay/notify raise, etc.) must not orphan the
          # just-granted member-cap. `do_join_apply` returns `{:ok, _, _}` or
          # RAISES (it has no `{:error}` return path), so the rescue is the sole
          # compensation trigger; it revokes only what THIS call granted, then
          # re-propagates (let-it-crash — the join still fails loudly).
          try do
            do_join_apply(member_uri, member_pid, ctx, facets, source_module)
          rescue
            e ->
              if granted?, do: MemberCap.revoke_at_join(member_uri, ctx)
              reraise e, __STACKTRACE__
          end
        end
    end
  end

  # --- Part C admission gate (spec §C.1/§C.2/§C.3, R4) ---------------------

  # The admission trigger predicate (spec §C.1). Fire PENDING iff:
  #   * the member is NOT already mounted (a rejoin / re-add of an established
  #     member is never pended — it already holds its member-cap), AND
  #   * `ctx.caller` is a REAL, non-system entity — a well-formed bare identity
  #     principal `entity://<ws>/<user|agent|worker>/<name>` (rejects nil /
  #     `:vm_internal` / `system://…` / malformed via `Ezagent.URI.bare_principal?/1`),
  #     AND
  #   * the caller is NOT the member itself (self-join / anon self-admission mount),
  #     AND
  #   * the caller does NOT hold manage-authority over the member
  #     (`Ezagent.Identity.Authority.manages?/2`, resolved from the caller's DURABLE
  #     identity caps by URI + the admin UNION — so the materializer's `admin_uri`
  #     caller, whose ctx.caps carry only a narrow inline join cap, is exempt via
  #     `manages?(admin_uri, member) = true` and NEVER stalls at PENDING).
  defp admission_pending?(%URI{} = member_uri, ctx) do
    members = ctx[:read].(:members, %{})
    caller = Map.get(ctx, :caller)

    # Scope to CREDENTIAL-BEARING members (agents/workers), spec §C.2. STRUCTURAL,
    # not a heuristic: the A2 receive-split routes `:receive` to `Agent.Receive`
    # (active live-worker delivery via the bridge — THE OAuth spend) for agents and
    # to `User.Receive` (a passive inbox write) for users. So the credential-spend
    # surface this gate protects IS exactly the non-user receive path — a USER
    # member cannot spend a credential on receive even if delivered. Pending an
    # invited human (orchestrator `add_participant`, world invite) would therefore
    # be a pure over-fire with no threat-X coverage; a human's data-read access is
    # governed by the join-cap / invite-authority layer
    # (`provision_invited_join_authority`), NOT this gate.
    not Map.has_key?(members, member_uri) and
      not Ezagent.URI.type?(member_uri, :user) and
      Ezagent.URI.bare_principal?(caller) and
      not same_entity?(caller, member_uri) and
      not caller_controls_member?(caller, member_uri)
  end

  # The caller has authority over the member — the admission exemption (spec §C.1
  # (a)+(c)). True iff the caller:
  #   * MANAGES the member (K2 `Authority.manages?/2` — a `Manage`-over-member cap,
  #     admin union, or workspace-admin; covers owner-adds-own-agent + the
  #     materializer's admin_uri caller via the genesis wildcard), OR
  #   * holds a target-signed concrete cap over a member in the caller's durable
  #     spawn lineage — the Path-A replacement for the legacy
  #     `{:spawned_by, caller}` scope. The conjunction is load-bearing: the cap
  #     proves target authority delegated to this presenter, while lineage proves
  #     the caller actually spawned the member.
  #
  # ⚠️ SECURITY (spec §C.1 / threat X): the second branch is restricted to the
  # concrete target AND durable caller lineage. It MUST NOT be a general "holds
  # any cap covering the member" check: a co-tenant with an exact cap but no
  # lineage remains a cross-owner pull and must pend.
  #
  # `manages?/2` is checked FIRST so the common mounts (owner-adds-own, admin) never
  # take the second durable-caps read (short-circuit): the spawned-by read runs only
  # when `manages?` is false (the cross-owner-looking minority).
  defp caller_controls_member?(%URI{} = caller, %URI{} = member_uri) do
    Ezagent.Identity.Authority.manages?(caller, member_uri) or
      holds_spawned_member_authority?(caller, member_uri)
  end

  defp caller_controls_member?(_, _), do: false

  defp holds_spawned_member_authority?(%URI{} = caller, %URI{} = member_uri) do
    Ezagent.AgentLineage.spawned_in_lineage?(member_uri, caller) and
      caller
      |> Ezagent.EntityCaps.load()
      |> Enum.any?(&concrete_caller_cap_covers?(&1, caller, member_uri))
  end

  defp concrete_caller_cap_covers?(
         %Ezagent.Capability{instance: %URI{}, grantee_uri: %URI{} = grantee} = held,
         %URI{} = caller,
         %URI{} = member_uri
       ) do
    same_entity?(grantee, caller) and cap_covers_instance?(held, member_uri)
  end

  defp concrete_caller_cap_covers?(_held, _caller, _member_uri), do: false

  # Echoes the held cap's own kind/behavior/action/workspace axes into `needed` so
  # those four match trivially (sidestepping the asymmetric-`:any` rule), leaving
  # the INSTANCE axis as the only real constraint — the same technique as
  # `Authority.held_instance_covers_target?/2`.
  defp cap_covers_instance?(%Ezagent.Capability{} = held, %URI{} = member_uri) do
    needed = %{
      kind: held.kind,
      behavior: held.behavior,
      action: Ezagent.Capability.action_of(held),
      instance: member_uri,
      workspace_uri: held.workspace_uri
    }

    Ezagent.Capability.matches?(held, needed)
  end

  defp cap_covers_instance?(_, _), do: false

  defp same_entity?(%URI{} = a, %URI{} = b),
    do: Ezagent.URI.instance(a) == Ezagent.URI.instance(b)

  defp same_entity?(_, _), do: false

  # Record a pending admission request on the `:session` slice (spec §C.2): NO
  # member-cap granted, NO `:members` mount. Returns the join tuple with a
  # `:pending_members` set-effect (the `:members` projection is unchanged — the
  # pending member is not mounted on either axis). The pending MEMBER's managers
  # are notified (spec §C.3) so the owner can approve.
  defp record_pending_admission(%URI{} = member_uri, ctx) do
    members = ctx[:read].(:members, %{})
    pending = ctx[:read].(:pending_members, %{})
    request_ref = new_request_ref()

    entry = %{
      requested_by: Map.get(ctx, :caller),
      requested_at: DateTime.utc_now(),
      request_ref: request_ref
    }

    new_pending = Map.put(pending, member_uri, entry)

    # spec §C.3 — notify the pending MEMBER's managers (NOT the session's) with a
    # content-free approvable-request envelope. Inline (like the join-notify in
    # `do_join_apply`): synchronous here is safe — `managers_of/1` GenServer.calls
    # the MANAGERS' Kinds, never re-enters this Session Kind.
    notify_pending_managers(member_uri, ctx[:self_uri], request_ref)

    {:ok, %{members: Map.keys(members), pending: member_uri},
     [{:set, :pending_members, new_pending}]}
  end

  # An opaque handle A approves/denies (spec §C.2). Random, dependency-free.
  defp new_request_ref, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  # spec §C.3 — notify the pending MEMBER's managers (`managers_of(member) = A`),
  # NOT the session's managers (= B). Content-free approvable-request envelope:
  # `{member, session, request_ref}` only — no message body, no cap values (the
  # same content-free discipline as the Part B cascade). Reuses Part B's
  # `managers_of/1` machinery with the pending member as the explicit SUBJECT (the
  # non-obvious wiring point: the generic `{entity,:caps}` cascade would resolve
  # `managers_of(SESSION) = B`, the wrong target). Best-effort — a notify
  # failure/raise on one recipient is swallowed so the pending record still commits.
  defp notify_pending_managers(%URI{} = member_uri, session_uri, request_ref) do
    body = %{
      member: URI.to_string(member_uri),
      session: session_uri && URI.to_string(session_uri),
      request_ref: request_ref
    }

    member_uri
    |> Ezagent.Identity.Cascade.managers_of()
    |> Enum.each(fn %URI{} = manager -> notify_pending_one(manager, body) end)

    :ok
  end

  defp notify_pending_one(%URI{} = manager, body) do
    Ezagent.Notifications.notify(manager, %{
      type: :pending_admission,
      source: __MODULE__,
      body: body
    })
  rescue
    error ->
      Logger.warning(
        "Session.Membership: pending-admission notify failed for " <>
          "#{URI.to_string(manager)} (non-fatal, advisory): #{inspect(error)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "Session.Membership: pending-admission notify threw for " <>
          "#{URI.to_string(manager)} (non-fatal, advisory): #{inspect({kind, reason})}"
      )

      :ok
  end

  @doc """
  APPROVE a pending admission request (spec §C.4) — the deferred second half of
  join. The approver MUST hold manage-authority over the member
  (`Ezagent.Identity.Authority.manages?/2`); on approval, re-enter the EXACT
  grant+mount tail C.1 withheld by re-running `do_join/5` under the approver's
  authority (`manages?(approver, member) = true` ⇒ the trigger does NOT re-pend,
  so it grants the member-cap + `do_join_apply` mounts), then drop the
  `:pending_members` entry (as an EFFECT — so a SYNCHRONOUS raise in `do_join_apply`
  (monitor/replay/notify) aborts the whole approval and the request stays PENDING).

  ⚠️ Abort-safety scope (codex 2026-07-05, #166): the abort-safety above covers
  SYNCHRONOUS `do_join_apply` failures. The member-cap grant itself
  (`MemberCap.grant_at_join/2`) is `:async` best-effort — its `:ok` means the grant
  cast was BUFFERED, not committed. So a post-cast async-grant FAILURE can drop
  `:pending_members` and mount the member into `:members` WITHOUT the member-cap. This
  is NOT a credential-spend hole: by R1.1 (roster ⟂ authz) a roster entry that holds
  no member-cap CANNOT receive (`MemberReceive.authorize/1` denies) ⇒ A's credential
  is NOT spent, and `reconcile_after_load/2` ("caps win") drops the stale roster entry
  on the next activate. It is a stale-roster edge, not a half-mount that spends. The
  fail-closed hardening (make the at-join grant synchronous + checked across ALL join
  paths, not just approve) is tracked as #166.

  Cap-EXEMPT at the CapBAC layer (the approver holds no session cap on B's
  session) — authorized HERE, in-handler, by the `manages?` predicate. Returns
  `{:ok, result, effects}` / `{:error, reason}`.
  """
  @spec approve_admission(URI.t(), map(), module()) :: {:ok, map(), [term()]} | {:error, term()}
  def approve_admission(%URI{} = member_uri, ctx, source_module) do
    pending = ctx[:read].(:pending_members, %{})
    caller = Map.get(ctx, :caller)

    cond do
      not Map.has_key?(pending, member_uri) ->
        {:error, :not_pending}

      not Ezagent.Identity.Authority.manages?(caller, member_uri) ->
        {:error, :unauthorized}

      true ->
        case Ezagent.KindRegistry.lookup(member_uri) do
          {:ok, member_pid} ->
            with {:ok, result, join_effects} <-
                   do_join(member_uri, member_pid, ctx, %{}, source_module) do
              {:ok, Map.put(result, :approved, member_uri),
               join_effects ++ [{:set, :pending_members, Map.delete(pending, member_uri)}]}
            end

          :error ->
            {:error, {:member_not_registered, member_uri}}
        end
    end
  end

  @doc """
  DENY a pending admission request (spec §C.5) — a manager of the member drops the
  `:pending_members` entry. No cap was ever granted, so deny is a pure state-drop.
  Cap-exempt; authorized in-handler by `manages?(actor, member)`.
  """
  @spec deny_admission(URI.t(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def deny_admission(%URI{} = member_uri, ctx) do
    pending = ctx[:read].(:pending_members, %{})
    caller = Map.get(ctx, :caller)

    cond do
      not Map.has_key?(pending, member_uri) ->
        {:error, :not_pending}

      not Ezagent.Identity.Authority.manages?(caller, member_uri) ->
        {:error, :unauthorized}

      true ->
        {:ok, %{denied: member_uri}, [{:set, :pending_members, Map.delete(pending, member_uri)}]}
    end
  end

  @doc """
  WITHDRAW a pending admission request (spec §C.5) — the REQUESTER (B) drops its
  own pending request. Authz: `requested_by == actor`. Cap-exempt; authorized
  in-handler.
  """
  @spec withdraw_admission(URI.t(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def withdraw_admission(%URI{} = member_uri, ctx) do
    pending = ctx[:read].(:pending_members, %{})
    caller = Map.get(ctx, :caller)

    case Map.get(pending, member_uri) do
      nil ->
        {:error, :not_pending}

      %{requested_by: requested_by} ->
        if same_entity?(caller, requested_by) do
          {:ok, %{withdrawn: member_uri},
           [{:set, :pending_members, Map.delete(pending, member_uri)}]}
        else
          {:error, :unauthorized}
        end
    end
  end

  defp do_join_apply(%URI{} = member_uri, member_pid, ctx, facets, source_module) do
    session_uri = ctx[:self_uri]
    members = ctx[:read].(:members, %{})
    # `:monitors` is a TRANSIENT (SPEC §2.3C) — read from ctx.transients.
    monitors = (ctx[:transients] || %{})[:monitors] || %{}
    last_seen = ctx[:read].(:last_seen, %{})
    prior_owner = ctx[:read].(:owner_uri, nil)

    # Drop ALL stale monitor entries for this member URI and DEMONITOR
    # each ref (Codex r1 MEDIUM-3, 2026-05-26).
    {old_refs_for_member, monitors_without_member} =
      Enum.split_with(monitors, fn {_ref, uri} ->
        URI.to_string(uri) == URI.to_string(member_uri)
      end)

    for {ref, _uri} <- old_refs_for_member do
      _ = Process.demonitor(ref, [:flush])
    end

    monitors_without_member = Map.new(monitors_without_member)

    ref = Process.monitor(member_pid)

    # team-routing-unification §3.1 (codex PR-5a HIGH #2) — PRESERVE any
    # facets a faceted member already carries when it rejoins through the
    # stale-monitor / offline path. Start from the EXISTING meta (not a fresh
    # `%{online: true}`), force `online: true`, then overlay only the non-nil
    # facets this join supplied. Durable management/snapshot facets therefore
    # survive reconnect/repair instead of being silently dropped.
    existing_meta = Map.get(members, member_uri, %{})

    new_members =
      Map.put(
        members,
        member_uri,
        Members.put_member_facets(Map.put(existing_meta, :online, true), facets)
      )

    new_monitors = Map.put(monitors_without_member, ref, member_uri)

    # If this member has prior last_seen, replay missed messages.
    Delivery.replay_messages_since(session_uri, member_uri, last_seen)
    new_last_seen = Map.delete(last_seen, member_uri)

    # RFC #402 (Allen 2026-05-26) — "first user to join is owner" fallback.
    #
    # #51 codex P1 (security): an ANONYMOUS external viewer
    # (`entity://<ws>/user/anon-<rand>`) MUST NEVER claim ownership. If an
    # ownerless session (spawned without `owner_uri`, or a legacy nil) is
    # opened via the public-view flow, the joining anon user would otherwise
    # become owner — a privilege escalation that flatly contradicts the
    # membership-only, read-only anon model. Anon users are excluded from the
    # owner transition; an ownerless session simply stays
    # ownerless (read-only viewing needs no owner).
    claims_owner? = is_nil(prior_owner) and user_uri?(member_uri) and not anon_member?(member_uri)

    new_owner_uri = if claims_owner?, do: member_uri, else: prior_owner

    # Notifier/flash audit 2026-05-24 — todo.md "Notifications consumer
    # coverage" — surface the join to the joinee's notification stream
    # so a freshly-added member sees they were added to a session.
    if user_uri?(member_uri) do
      _ =
        Ezagent.Notifications.notify(member_uri, %{
          type: :session_member_joined,
          body: %{
            text: "You joined session #{URI.to_string(session_uri)}.",
            session_uri: session_uri
          },
          source: source_module
        })
    end

    {:ok, %{members: Map.keys(new_members)},
     [
       {:set, :members, new_members},
       # `:monitors` is a TRANSIENT (SPEC §2.3C / §7 OQ-2) — written via
       # `:set_transient`, never persisted.
       {:set_transient, :monitors, new_monitors},
       {:set, :last_seen, new_last_seen},
       {:set, :owner_uri, new_owner_uri}
     ] ++ Delivery.broadcast_membership_effects(session_uri, {:member_joined, member_uri})}
  end

  @doc """
  Atomically relabel a session member from one URI to another.

  This composes `do_join/5` directly, then rewrites the post-join effect set so
  the anon removal, monitor cleanup, `last_seen` cleanup, `last_message` relabel,
  and membership broadcasts commit as one Session slice mutation. It deliberately
  contains no socialware symbols; the web/socialware orchestrator owns the
  binding claim, message-store relabel, cap mounting, and anon retirement.
  """
  @spec do_merge_member(URI.t(), URI.t(), map(), module()) ::
          {:ok, map(), [term()]} | {:error, term()}
  def do_merge_member(%URI{} = from_uri, %URI{} = to_uri, ctx, source_module) do
    session_uri = ctx[:self_uri]

    if Ezagent.URI.instance(from_uri) == Ezagent.URI.instance(to_uri) do
      members = ctx[:read].(:members, %{})
      {:ok, %{members: Map.keys(members)}, []}
    else
      with {:ok, member_pid} <- lookup_merge_target(to_uri),
           {:ok, _join_result, join_effects} <-
             do_join(to_uri, member_pid, ctx, %{}, source_module) do
        build_merge_member_effects(session_uri, from_uri, to_uri, ctx, join_effects)
      end
    end
  end

  defp lookup_merge_target(%URI{} = to_uri) do
    case Ezagent.KindRegistry.lookup(to_uri) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, {:member_not_registered, to_uri}}
    end
  end

  defp build_merge_member_effects(session_uri, from_uri, to_uri, ctx, join_effects) do
    # Read-marker repoint is a cross-store (read_markers DB) write that must
    # converge before the membership slice mutation commits. Do it FIRST and
    # ABORT the merge on failure — before any irreversible side-effect
    # (demonitor) and before emitting the members/last_seen effects — so a
    # repoint error never leaves read_markers rows pointing at a to-be-retired
    # anon (FINAL design §3 "zero surviving refs"; `feedback_let_it_crash_no_workarounds`).
    # `repoint/3` is idempotent, so the orchestrator's re-run after an abort is safe.
    case repoint_read_markers(session_uri, from_uri, to_uri) do
      :ok ->
        members_after_join =
          effect_value(join_effects, :set, :members, ctx[:read].(:members, %{}))

        monitors_after_join =
          effect_value(
            join_effects,
            :set_transient,
            :monitors,
            (ctx[:transients] || %{})[:monitors] || %{}
          )

        last_seen_after_join =
          effect_value(join_effects, :set, :last_seen, ctx[:read].(:last_seen, %{}))

        new_members = Map.delete(members_after_join, from_uri)

        {from_ref, monitors_after_from} = Delivery.pop_monitor_ref(monitors_after_join, from_uri)
        if from_ref, do: Process.demonitor(from_ref, [:flush])

        new_last_seen = Map.delete(last_seen_after_join, from_uri)
        last_message = rewrite_last_message(ctx[:read].(:last_message, nil), from_uri, to_uri)

        passthrough =
          Enum.reject(join_effects, &merge_member_owned_effect?/1)

        effects =
          [
            set_effect(:members, new_members),
            transient_effect(:monitors, monitors_after_from),
            set_effect(:last_seen, new_last_seen)
          ] ++
            last_message_effect(last_message) ++
            passthrough ++
            Delivery.broadcast_membership_effects(session_uri, {:member_left, from_uri})

        {:ok, %{members: Map.keys(new_members)}, effects}

      {:error, _reason} = err ->
        err
    end
  end

  defp repoint_read_markers(session_uri, from_uri, to_uri) do
    case Ezagent.Session.ReadMarker.repoint(session_uri, from_uri, to_uri) do
      {:ok, _moved} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Session.Membership.do_merge_member: ReadMarker.repoint failed for " <>
            "#{URI.to_string(from_uri)} -> #{URI.to_string(to_uri)} in " <>
            "#{URI.to_string(session_uri)}: #{inspect(reason)} — aborting merge"
        )

        {:error, {:read_marker_repoint_failed, reason}}
    end
  end

  defp rewrite_last_message(nil, _from_uri, _to_uri), do: nil

  defp rewrite_last_message(%Ezagent.Message{} = message, from_uri, to_uri) do
    %{
      message
      | sender: rewrite_uri(message.sender, from_uri, to_uri),
        mentions: rewrite_uris(message.mentions, from_uri, to_uri)
    }
  end

  defp rewrite_last_message(other, _from_uri, _to_uri), do: other

  defp rewrite_uris(uris, from_uri, to_uri) when is_list(uris) do
    Enum.map(uris, &rewrite_uri(&1, from_uri, to_uri))
  end

  defp rewrite_uris(other, _from_uri, _to_uri), do: other

  defp rewrite_uri(%URI{} = uri, from_uri, to_uri) do
    if Ezagent.URI.instance(uri) == Ezagent.URI.instance(from_uri), do: to_uri, else: uri
  end

  defp rewrite_uri(other, _from_uri, _to_uri), do: other

  defp last_message_effect(nil), do: []
  defp last_message_effect(message), do: [set_effect(:last_message, message)]

  defp set_effect(key, value), do: {:set, key, value}
  defp transient_effect(key, value), do: {:set_transient, key, value}

  defp merge_member_owned_effect?({kind, key, _})
       when kind == :set and key in [:members, :last_seen],
       do: true

  defp merge_member_owned_effect?({kind, key, _})
       when kind == :set_transient and key == :monitors,
       do: true

  defp merge_member_owned_effect?(_), do: false

  defp effect_value(effects, effect_kind, key, default) do
    Enum.find_value(effects, default, fn
      {^effect_kind, ^key, value} -> value
      _ -> false
    end)
  end

  # Notifier/flash audit 2026-05-24 — same predicate
  # `Ezagent.Domain.Workspace.user_uri?/1` uses. Keeps the agent-target
  # silence guarantee local to Chat without crossing the
  # workspace-domain boundary.
  @doc """
  True iff `uri` is an `entity://user/...` URI. Mirrors
  `Ezagent.Domain.Workspace.user_uri?/1` to keep the agent-target silence
  guarantee local to Chat.
  """
  @spec user_uri?(term()) :: boolean()
  def user_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  def user_uri?(_), do: false

  # #51 codex P1 — an anonymous external viewer by the reserved naming
  # convention `entity://<ws>/user/anon-<rand>`. Used ONLY to suppress the
  # first-join owner-claim (above); a string check on the name keeps this in
  # the session domain with no dependency on the socialware View layer that
  # mints them (mirrors `Ezagent.Socialware.AnonUser.anon_uri?/1`). The
  # suppression direction is safe even if a non-anon user is mis-named
  # `anon-…`: it would only DECLINE ownership, never escalate.
  #
  # #154 spec 甲 (2026-06-19): the AUTHORITATIVE anon signal is now
  # `users.confirmed == false` (PR-甲-1 added the attribute + `Users.confirmed?/1`).
  # This function STILL uses the name-prefix because it runs inside the Session
  # Kind's GenServer (`handle_join`), where a synchronous `Repo` read is both a
  # sandbox-ownership hazard in tests and a hot-path DB coupling in prod. PR-甲-2
  # reworks the join flow to resolve the member CLASS at the caller/dispatch layer
  # (which holds DB access) and pass it into `handle_join`, at which point this
  # name-prefix check is replaced by the `confirmed` attribute and retired.
  @anon_user_name_prefix "anon-"
  def anon_member?(%URI{scheme: "entity"} = uri) do
    user_uri?(uri) and
      case uri |> URI.to_string() |> String.split("/") |> List.last() do
        nil -> false
        name -> String.starts_with?(name, @anon_user_name_prefix)
      end
  end

  def anon_member?(_), do: false

  # `:attach` (LV→world parity PR-2b) is co-granted with `:send`: a confirmed
  # member who may post a message may also upload a file attachment to it. The
  # upload controller dispatches `:session :attach`, which authorizes against
  # this cap at the chokepoint (no `:send` alias — the runtime checks the
  # dispatched action name, so upload needs its own real `:attach` cap).
  @member_chat_actions [:send, :leave, :attach]
  @member_publisher_actions [:subscribe_from]

  @doc """
  Provision the per-session `:join` authority on a prospective joiner BEFORE the
  `session.join` dispatch, rooted at SESSION POLICY (#154 spec 甲 / PR-甲-2 §B —
  the chicken-and-egg fix).

  ## Why this exists

  `session.join` is itself cap-gated: `Behavior.Session action(:join, caps: [:join])`
  ⇒ dispatch step-5.5 requires the caller hold
  `cap(:session, Session, :join, instance: <session>)`. Before this PR that cap
  came from `User.default_caps`'s broad workspace-wide `cap(:session, :any, :any)`
  baseline. PR-甲-2 narrows that baseline to `[]`, so the join authority must be
  rooted at the session OWNER instead of an ambient universal baseline — otherwise
  every self-join / invite path loses its `:join` cap (the prior branch's 8
  failures).

  This grant is the JUST-IN-TIME per-session join cap, distinct from the
  participation TIER (`mount_participation_caps/2`, granted AFTER a successful
  join). Per spec §3.1 `:join` is never in a mounted tier — it is provisioned
  here, ahead of the dispatch, exactly as `anon_user.mint_for_public_session/1`
  mints the anon's join cap. It is granted `:sync` (caller-side, ordinary
  cross-process `Session.owner` call — no self-deadlock) so it lands in the
  joiner's slice BEFORE the dispatch; the runtime authorizes the subsequent join
  via the live slice read (`granted_via_holds_cap?`).

  ## Policy (who may be provisioned a join cap)

    * joiner is the session OWNER, or an existing MEMBER → provision; granter =
      owner (owner-rooted — spec §8 g2).
    * ownerless session + a NON-anon user joiner → provision the first-non-anon
      join so it can claim ownership (RFC #402); granter = `entity://system/user/admin`
      (the #154 named extreme-case granter, spec §8 g2 exception (ii)).
    * anyone else (a non-owner non-member self-joining a private session) →
      `{:error, :no_authority}`: NOT provisioned, so the existing `session.join`
      dispatch returns `{:error, :unauthorized}` and the access point degrades to
      "observe" (spec §8 g1).

  `public_view` open-join is NOT handled here — that is the anon web path, whose
  join cap is minted by `anon_user.mint_for_public_session/1`. The admin LV
  (the caller of this function) serves owned/private sessions only.

  Returns `:ok` when a join cap is provisioned (or the joiner is an agent — agents
  carry their own caps), `{:error, :no_authority}` when policy denies provisioning.
  Best-effort on the GRANT itself: a failed grant dispatch is logged + telemetry'd
  and still returns `:ok` (the join then fails closed at the chokepoint → observe).
  """
  @spec provision_join_authority(URI.t(), URI.t()) :: :ok | {:error, :no_authority}
  def provision_join_authority(%URI{} = session_uri, %URI{} = joiner_uri) do
    cond do
      not user_uri?(joiner_uri) ->
        # Agents/workers carry their own provisioned caps (甲-3); the
        # system-internal creation joins (orchestrator) run under
        # `system://session-internal`. Nothing to provision here.
        :ok

      true ->
        do_provision_join_authority(session_uri, joiner_uri)
    end
  end

  def provision_join_authority(_, _), do: {:error, :no_authority}

  @doc """
  Provision join authority for an explicit session invite.

  Unlike `provision_join_authority/2`, this is not a self-join policy check.
  Callers must already have proven invite authority at their own boundary
  (the orchestrator tool preflights `{:within_session, session_uri}` before
  calling this). The grant remains narrow: a concrete `Session.:join` cap for
  this session only.

  ## Why the non-user (agent-reuse) branch returns `:ok` without an agent-owner check

  This is deliberate, NOT the "#161-shaped reuse-join hole" it can look like when
  read in isolation (`_inviter_uri` ignored + `else -> :ok`, flagged by the #1256
  bootstrap audit). Provisioning is only step one of an agent reuse-join; it never
  mounts the agent or grants a member-cap. The operator→agent credential-isolation
  gate lives ONE seam downstream, at the common `handle_join` member-cap grant seam
  that EVERY add path funnels through (§C.1 / R4, PR #161-c): `admission_pending?/2`
  PENDS a credential-bearing (non-user) member whose `ctx.caller` neither IS nor
  MANAGES it (`Authority.manages?/2` + the narrow `{:spawned_by, caller}` exemption
  — deliberately NOT "holds any cap covering it", so a co-tenant's broad
  `{:within_workspace}` cap cannot reopen threat X). A pended member holds no
  member-cap ⇒ `MemberReceive.authorize/1` denies receive ⇒ the owner's credential
  is not spent until the agent's owner `:approve_admission`s. Every operator-reachable
  reuse route (orchestrator `Participants.add_participant`, world `invite_member`,
  `definition_agents.reuse_existing_agent`) dispatches the join under the operator's
  OWN bare principal, so the gate fires for foreign agents. Empirically pinned by
  `admission_gate_test.exs` (test 28 cross-owner PENDS + the "within_workspace cap
  does NOT exempt" teeth) and `socialware_reuse_bind_test.exs` ("operator reuse-bind
  of a foreign agent pends through session.join"). Gating HERE instead would be a
  parallel idiom that hard-denies (breaking the pend/approve UX those tests assert)
  and misfires on legitimate owner-reuse (owner authority is `manages?`, not the
  spawn-lineage `AgentLineage` notion). So: forward the join; the admission gate decides.
  """
  @spec provision_invited_join_authority(URI.t(), URI.t(), URI.t()) ::
          :ok | {:error, :no_authority}
  def provision_invited_join_authority(
        %URI{} = session_uri,
        %URI{} = joiner_uri,
        %URI{} = _inviter_uri
      ) do
    if user_uri?(joiner_uri) do
      session_uri
      |> session_owner()
      |> owner_or_admin()
      |> then(fn granter -> grant_join_cap(session_uri, joiner_uri, granter) end)

      :ok
    else
      # Non-user (agent) reuse-join: forward to the Part C admission gate at
      # `handle_join` (§C.1/R4) — see the moduledoc "Why the non-user branch
      # returns :ok" above. The credential-spend gate is there, not here.
      :ok
    end
  end

  def provision_invited_join_authority(_, _, _), do: {:error, :no_authority}

  defp do_provision_join_authority(%URI{} = session_uri, %URI{} = joiner_uri) do
    owner = session_owner(session_uri)

    granter =
      case join_authority_basis(session_uri, joiner_uri, owner) do
        {:authorized, granter} -> granter
        :denied -> nil
      end

    case granter do
      nil ->
        {:error, :no_authority}

      %URI{} = granter ->
        grant_join_cap(session_uri, joiner_uri, granter)
        :ok
    end
  end

  # The owner-rooted join policy (spec §8 g1/g2). Returns the GRANTER for an
  # authorized join, or `:denied`.
  defp join_authority_basis(%URI{} = session_uri, %URI{} = joiner_uri, owner) do
    cond do
      # Owner self-join, or an existing member re-joining: owner-rooted.
      match?(%URI{}, owner) and joiner_uri == owner ->
        {:authorized, owner}

      already_member?(session_uri, joiner_uri) ->
        # An existing member re-navigating; the join is owner-authorized
        # (the member was added under the owner's authority). Granter = the
        # owner when present, else the admin fallback (ownerless legacy).
        {:authorized, owner_or_admin(owner)}

      # Ownerless session + a non-anon user: the first-non-anon-join owner-claim
      # (RFC #402). Granter = admin (the #154 named extreme-case granter).
      is_nil(owner) and not anon_member?(joiner_uri) ->
        {:authorized, Ezagent.Entity.User.admin_uri()}

      true ->
        :denied
    end
  end

  defp owner_or_admin(%URI{} = owner), do: owner
  defp owner_or_admin(_), do: Ezagent.Entity.User.admin_uri()

  defp session_owner(%URI{} = session_uri) do
    case Ezagent.Entity.Session.owner(session_uri) do
      {:ok, %URI{} = owner} -> owner
      _ -> nil
    end
  end

  defp already_member?(%URI{} = session_uri, %URI{} = joiner_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{state: %{members: members}}} when is_map(members) ->
        Map.has_key?(members, joiner_uri)

      {:ok, %{members: members}} when is_map(members) ->
        Map.has_key?(members, joiner_uri)

      _ ->
        false
    end
  end

  defp grant_join_cap(%URI{} = session_uri, %URI{} = joiner_uri, %URI{} = granter) do
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)

    # Idempotency: if the joiner already holds a cap authorizing `:join` on this
    # session (admin's wildcard, the anon's own minted join cap, or a prior
    # provision), skip — avoids re-grant slice churn on every navigation.
    if already_authorized?(
         Ezagent.Identity.list_caps_for(joiner_uri),
         Ezagent.ActionSet.Session,
         :join,
         session_uri,
         workspace_uri
       ) do
      :ok
    else
      do_grant_join_cap(session_uri, joiner_uri, granter, workspace_uri)
    end
  end

  @doc """
  The membership-removal effect list, shared by `:leave` and the
  `:remove_participant` primitive (F7 PR-A §3.2 step 3). Drops `member_uri` +
  its monitor + last_seen and emits the `{:member_left}` broadcast — the
  surface-agnostic convergence signal (§5.4). Factored out so
  `remove_participant` runs the SAME leave (leave-FIRST, then teardown) and the
  `{:member_left}` broadcast always fires.

  The `:leave` path has NO fallible follow-up step, so it demonitors the stale
  ref immediately. The `:remove_participant` path uses `leave_effects_with_ref/2`
  instead so it can defer the demonitor to apply-time, AFTER the fallible
  prune/teardown succeeds (F7 PR-B / codex PR-A LOW — see that function).
  """
  @spec leave_effects(URI.t(), map()) :: [term()]
  def leave_effects(%URI{} = member_uri, ctx) do
    # Membership-cap unification A2.4 (spec R3.1 LEAVE) — self-leave has NO
    # fallible follow-up step (`leave_effects_with_ref/2` is pure effect
    # computation), so revoke the member-cap FIRST, then drop the projection.
    # Best-effort: a revoke failure is logged (reconcile heals); R1.1 means a
    # projection-drop failure has no authz window (receive reads the held cap).
    # (Revoke wrappers live in the sibling `MemberCap`, co-located with the grant.)
    _ = MemberCap.revoke_member_cap_best_effort(member_uri, ctx)

    {ref_to_remove, effects} = leave_effects_with_ref(member_uri, ctx)
    if ref_to_remove, do: Process.demonitor(ref_to_remove, [:flush])
    effects
  end

  @doc """
  Like `leave_effects/2` but returns `{stale_monitor_ref | nil, effects}` and
  does NOT demonitor — the caller decides WHEN to `Process.demonitor` (codex
  PR-A LOW, F7 PR-B step 4).

  ## Why the split

  `Process.demonitor(ref, [:flush])` is an irreversible side-effect. The old
  `leave_effects/2` ran it EAGERLY during effect-COMPUTATION, before
  `remove_participant`'s fallible routing-prune / worker-teardown. On a prune or
  teardown FAILURE the handler returns `{:error, _}` and the membership `{:set}`
  effects are DISCARDED — so the member kept its membership but had ALREADY lost
  its monitor (a silently un-monitored live member). Moving the demonitor to
  apply-time (the caller invokes it only after prune+teardown succeed, just
  before returning `{:ok, …}`) keeps the member fully monitored on any failure
  path — membership + monitor commit or roll back together.
  """
  @spec leave_effects_with_ref(URI.t(), map()) :: {reference() | nil, [term()]}
  def leave_effects_with_ref(%URI{} = member_uri, ctx) do
    members = ctx[:read].(:members, %{})
    # `:monitors` is a TRANSIENT (SPEC §2.3C) — read from ctx.transients.
    monitors = (ctx[:transients] || %{})[:monitors] || %{}
    last_seen = ctx[:read].(:last_seen, %{})

    {ref_to_remove, new_monitors} = Delivery.pop_monitor_ref(monitors, member_uri)

    new_members = Map.delete(members, member_uri)
    new_last_seen = Map.delete(last_seen, member_uri)

    effects =
      [
        {:set, :members, new_members},
        # `:monitors` is a TRANSIENT (SPEC §2.3C / §7 OQ-2).
        {:set_transient, :monitors, new_monitors},
        {:set, :last_seen, new_last_seen}
      ] ++ Delivery.broadcast_membership_effects(ctx[:self_uri], {:member_left, member_uri})

    {ref_to_remove, effects}
  end

  @doc """
  The isomorphic `remove_participant` handler body (F7 PR-A, SPEC §3.2 / §3.3).
  Extracted from `Behavior.Session` (gt_1000 LOC gate). Runs inside the Session
  Kind process (members slice readable via `ctx`).

  1. **Owner-gate (§3.3, load-bearing).** Authorize when `caller == owner_uri` OR
     `caller == participant` (self-leave) OR the bootstrap admin. Else
     `{:error, :unauthorized}` before any mutation (fail-closed) — defense-in-depth
     on the dispatch chokepoint's `:remove_participant` cap.
  2. **Provenance branch (§3.2, NOT user-vs-agent).** A participant SPAWNED INTO
     this session (carries a `:source_template_uri` facet AND is in the owner's
     spawn lineage) → reap its worker (config-dir GC + scheduled termination)
     under the OWNER's `{:spawned_by, owner_uri}` teardown cap, then forget its
     lineage (`Teardown.teardown_participant_resources/4`, `:strict`). Facet
     absent / not-in-lineage → user / invited agent → membership-only.
  3. **Leave-FIRST + atomic (§5.4 / F7 PR-B).** Compute the leave effects (NO
     eager demonitor), reap the worker (`:strict` — a missing teardown cap FAILS
     CLOSED before anything irreversible), prune routing (shared `RoutingPrune`,
     session-scoped), THEN demonitor at apply-time and return — so a teardown or
     prune failure leaves membership + monitor intact (codex PR-A LOW fix).

  Returns `{:ok, map, effects}` / `{:ok, :already_removed, []}` / `{:error, _}`.
  """
  @spec handle_remove_participant(URI.t(), map()) ::
          {:ok, map(), [term()]} | {:ok, :already_removed, []} | {:error, term()}
  def handle_remove_participant(%URI{} = participant_uri, ctx) do
    members = ctx[:read].(:members, %{})
    owner_uri = ctx[:read].(:owner_uri, nil)
    caller = ctx[:caller]

    cond do
      not remove_participant_authorized?(caller, participant_uri, owner_uri) ->
        {:error, :unauthorized}

      not Map.has_key?(members, participant_uri) ->
        {:ok, :already_removed, []}

      true ->
        do_remove_participant(participant_uri, Map.get(members, participant_uri, %{}), ctx)
    end
  end

  # Owner-gate (§3.3): owner OR self-leave OR admin. Fail-closed. The admin check
  # goes through the canonical `Ezagent.Identity.admin?/1`, not a hand-written
  # equality against the admin principal (cap_check_only_at_chokepoint probe p13).
  defp remove_participant_authorized?(%URI{} = caller, %URI{} = participant_uri, owner_uri) do
    caller == participant_uri or
      (match?(%URI{}, owner_uri) and caller == owner_uri) or
      Ezagent.Identity.admin?(caller)
  end

  defp remove_participant_authorized?(_caller, _participant, _owner), do: false

  defp do_remove_participant(%URI{} = participant_uri, participant_meta, ctx)
       when is_map(participant_meta) do
    session_uri = ctx[:self_uri]
    owner_uri = ctx[:read].(:owner_uri, nil)

    # Compute the leave effects FIRST (carry the {:member_left} broadcast →
    # convergence) but DEFER the demonitor to apply-time (codex PR-A LOW).
    {leave_ref, leave} = leave_effects_with_ref(participant_uri, ctx)

    # The worker reap (`:strict`) is the AUTHORITY GATE and the only irreversible
    # step. Run it BEFORE the routing prune so a missing teardown cap fails
    # CLOSED with ZERO mutation (the "owner without destroy cap denied" case).
    case Ezagent.ActionSet.Session.Teardown.teardown_participant_resources(
           participant_uri,
           participant_meta,
           owner_uri,
           :strict
         ) do
      {:error, _} = err ->
        # Fail-closed before anything irreversible/committed — no membership
        # mutation, member keeps its monitor.
        err

      {:ok, :worker} ->
        # The worker is now IRREVERSIBLY reaped (config-dir GC'd, lineage
        # forgotten, process terminating). The member MUST be dropped now — a
        # later routing-prune failure must NOT abort the leave, else a zombie
        # member would reference a dead worker with no {:member_left} broadcast
        # (codex Q4 / SPEC §7 "Silent orphan"). So the prune is BEST-EFFORT once
        # the reap has happened.
        {deleted, repointed} =
          case Ezagent.ActionSet.Session.RoutingPrune.prune_routing_rules_for(
                 session_uri,
                 participant_uri
               ) do
            {:ok, %{deleted_rules: deleted, repointed_rules: repointed}} ->
              {deleted, repointed}

            {:error, reason} ->
              Logger.warning(
                "remove_participant: routing prune failed after partial worker retirement: " <>
                  inspect(reason)
              )

              {0, 0}
          end

        # A2.4 (R3.1) — the security-critical member-cap REVOKE, CHECKED. Placed
        # after the teardown authority + prune have run so a rejected removal
        # never reaches it. NOTE (R3.1 destructive-teardown edge): the current
        # teardown reaps the worker BEFORE this revoke, so a revoke failure here
        # leaves worker-dead + cap-held — a RESOURCE leak (reconciled), not a
        # security regression (§14.5 asserts revoke⇒deny, never worker-destroyed).
        # Fully separating the destructive teardown to AFTER the revoke needs a
        # chokepoint-compatible authority preflight (deferred; see final report).
        with :ok <-
               Ezagent.Socialware.CompositionCaps.deactivate_member(
                 session_uri,
                 participant_uri,
                 :role_departure
               ),
             :ok <- MemberCap.revoke_member_cap_checked(participant_uri, ctx) do
          if leave_ref, do: Process.demonitor(leave_ref, [:flush])

          {:ok,
           %{
             status: :removed,
             torn_down: :worker,
             deleted_rules: deleted,
             repointed_rules: repointed
           }, leave}
        end

      {:partial, %{resource: :worker, retirement: retirement}} ->
        # Termination is irreversible, while durable obligation ownership makes
        # the remaining cleanup recoverable. Drop the zombie-prone membership,
        # but expose the obligation instead of reporting full cleanup.
        {deleted, repointed} = prune_worker_after_retirement(session_uri, participant_uri)

        with :ok <-
               Ezagent.Socialware.CompositionCaps.deactivate_member(
                 session_uri,
                 participant_uri,
                 :role_departure
               ),
             :ok <- MemberCap.revoke_member_cap_checked(participant_uri, ctx) do
          if leave_ref, do: Process.demonitor(leave_ref, [:flush])

          {:ok,
           %{
             status: :removed,
             torn_down: :worker,
             cleanup: :pending,
             cleanup_obligation_id: retirement.obligation_id,
             deleted_rules: deleted,
             repointed_rules: repointed
           }, leave}
        end

      {:ok, :membership_only} ->
        # Nothing irreversible happened → the prune is fail-closed/atomic: the
        # member drops ONLY if the prune commits (PR-A behavior preserved).
        case Ezagent.ActionSet.Session.RoutingPrune.prune_routing_rules_for(
               session_uri,
               participant_uri
             ) do
          {:ok, %{deleted_rules: deleted, repointed_rules: repointed}} ->
            # A2.4 (R3.1) — checked, abort-safe member-cap revoke AFTER every
            # rejecting check (teardown authority + prune) has passed. On failure
            # the removal ABORTS and the member is left fully intact (cap +
            # roster). No destructive step ran on this branch, so abort is clean.
            with :ok <-
                   Ezagent.Socialware.CompositionCaps.deactivate_member(
                     session_uri,
                     participant_uri,
                     :role_departure
                   ),
                 :ok <- MemberCap.revoke_member_cap_checked(participant_uri, ctx) do
              if leave_ref, do: Process.demonitor(leave_ref, [:flush])

              {:ok,
               %{
                 status: :removed,
                 torn_down: :membership_only,
                 deleted_rules: deleted,
                 repointed_rules: repointed
               }, leave}
            end

          {:error, _reason} = err ->
            err
        end
    end
  end

  # Routing prune AFTER an irreversible worker reap (codex Q4). The member is
  # being dropped regardless, so a prune failure is logged + swallowed (stale
  # rows for a now-dead member are harmless and get cleaned out-of-band) rather
  # than aborting the leave into a zombie-member orphan.
  defp prune_worker_after_retirement(%URI{} = session_uri, %URI{} = participant_uri) do
    case Ezagent.ActionSet.Session.RoutingPrune.prune_routing_rules_for(
           session_uri,
           participant_uri
         ) do
      {:ok, %{deleted_rules: deleted, repointed_rules: repointed}} ->
        {deleted, repointed}

      {:error, reason} ->
        Logger.warning(
          "remove_participant: routing prune FAILED after the worker reap for " <>
            "#{inspect(participant_uri)}: #{inspect(reason)} — member dropped anyway " <>
            "(no zombie); stale routing rows left for out-of-band cleanup."
        )

        {0, 0}
    end
  end

  @doc """
  Build the inline SELF-LEAVE cap (F7 PR-A, SPEC §3.3): a self-scoped
  `cap(:session, Session, :remove_participant, <session_uri>)` with
  `granted_by: member_uri` (genuine self-authority per capbac.md §7 — a member
  may always remove ITSELF).

  The front-ends add this to the dispatch `ctx.caps` when `participant == caller`
  so a self-leaver (who otherwise holds only the `:leave`/`:send` participation
  tier) clears the dispatch chokepoint; the handler's identity gate then confirms
  `caller == participant`. It is an INLINE ctx cap (the same ctx-construction
  pattern the operator CLIs + materializer use) — NOT a persisted grant, so the
  entry needs no `Identity.list_caps_for` read (cap_check_only_at_chokepoint p6).
  """
  @spec self_remove_participant_cap(URI.t(), URI.t()) :: Ezagent.Capability.t()
  def self_remove_participant_cap(%URI{} = session_uri, %URI{} = member_uri) do
    %Ezagent.Capability{
      Ezagent.Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :remove_participant,
        session_uri,
        Ezagent.Capability.workspace_of(session_uri)
      )
      | granted_by: member_uri,
        granted_at: DateTime.utc_now()
    }
  end

  defp do_grant_join_cap(session_uri, joiner_uri, granter, workspace_uri) do
    cap =
      Ezagent.Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :join,
        session_uri,
        workspace_uri
      )

    authorization = grant_authorization(granter)

    result =
      with :ok <- Ezagent.Identity.TargetAuthority.ensure(granter, session_uri) do
        Ezagent.Identity.Grant.grant_cap_via_router(joiner_uri, cap, authorization, :sync)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Session.Membership.provision_join_authority: join-cap grant failed for " <>
            "joiner=#{URI.to_string(joiner_uri)} on session=" <>
            "#{URI.to_string(session_uri)}: #{inspect(reason)} " <>
            "(best-effort; join fails closed → observe)."
        )

        :telemetry.execute(
          [:ezagent, :session, :join_cap, :failed],
          %{count: 1},
          %{session_uri: session_uri, joiner_uri: joiner_uri, reason: reason}
        )

        :ok
    end
  end

  @doc """
  Mount the per-session participation cap tier on a freshly-joined member
  (#154 spec 甲 / PR-甲-2). Called by the TRUSTED join access points (LV
  self-join, invite, home, anon mint) AFTER a successful join — never inside
  `handle_join` (a DB read in the Session Kind is the 甲-1 sandbox/hot-path
  hazard) and never from forgeable join args.

  By-design-secure ([[feedback_analyze_caller_before_defending]]): the tier is
  chosen from the AUTHORITATIVE `Ezagent.Users.confirmed?/1` (a DB fact),
  resolved here in the CALLER's process (which has DB access), NOT from any
  caller-supplied input — so there is nothing to forge and no anti-forgery
  guard is needed. Running caller-side (not in the Session Kind) also means the
  grant's `Session.owner` lookup is an ordinary cross-process call, so the
  grant is `:sync` (no self-deadlock — unlike `grant_first_join_owner_cap`).

  Tiers (scoped to THIS session instance):
    * unconfirmed user → `Publisher.SessionImpl.:subscribe_from` (read-only)
    * confirmed user   → the above + `Session.:send` + `Session.:leave`
    * agent            → no-op (agents get `:send` provisioned at spawn, 甲-3)

  Authority `{:rule, :session_participation, owner}` (concrete instance +
  action ⇒ `rule_cap_bounded?` ⇒ the rule branch authorizes; `granted_by` =
  owner entity). Owner = the session owner; for an ownerless session it falls
  back to `entity://system/user/admin` (the #154 named extreme-case granter,
  same as `anon_user.public_view_granter/1`). Best-effort: a failed grant is
  logged + telemetry'd, never raised — a missing participation cap degrades to
  "observe", it does not break the join.
  """
  @spec mount_participation_caps(URI.t(), URI.t()) :: :ok
  def mount_participation_caps(%URI{} = session_uri, %URI{} = member_uri) do
    if user_uri?(member_uri) do
      do_mount_participation_caps(session_uri, member_uri)
    else
      :ok
    end
  end

  def mount_participation_caps(_, _), do: :ok

  # The session OWNER is the participation granter (the #154 owner-rooted rule);
  # an ownerless session falls back to the admin entity (the named extreme-case
  # granter, same as `anon_user.public_view_granter/1`). Resolved HERE (caller
  # process, cross-process `Session.owner` call — no self-deadlock) so the
  # access-point callers don't each have to look it up.
  defp do_mount_participation_caps(%URI{} = session_uri, %URI{} = member_uri) do
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)
    granter = session_owner(session_uri) |> owner_or_admin()
    authorization = grant_authorization(granter)

    _ = Ezagent.Identity.TargetAuthority.ensure(granter, session_uri)

    confirmed? = Ezagent.Users.confirmed?(member_uri)

    actions =
      if confirmed? do
        Enum.map(@member_chat_actions, &{Ezagent.ActionSet.Session, &1}) ++
          Enum.map(@member_publisher_actions, &{Ezagent.ActionSet.Publisher.SessionImpl, &1})
      else
        Enum.map(@member_publisher_actions, &{Ezagent.ActionSet.Publisher.SessionImpl, &1})
      end

    held = Ezagent.Identity.list_caps_for(member_uri)

    Enum.each(actions, fn {behavior, action} ->
      cap =
        Ezagent.Capability.cap(:session, behavior, action, session_uri, workspace_uri)

      # Idempotency: skip the grant when the member ALREADY holds a cap that
      # authorizes this action (e.g. admin's bootstrap wildcard, or a prior
      # mount). Without this, every re-navigation re-grants (caps carry a fresh
      # `granted_at`, so the slice MapSet never dedupes) → spurious `:identity`
      # slice-change churn + flash noise on every session select.
      if already_authorized?(held, behavior, action, session_uri, workspace_uri) do
        :ok
      else
        case Ezagent.Identity.Grant.grant_cap_via_router(
               member_uri,
               cap,
               authorization,
               :sync
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Session.Membership.mount_participation_caps: grant failed for " <>
                "member=#{URI.to_string(member_uri)} on session=" <>
                "#{URI.to_string(session_uri)} action=#{inspect(action)}: " <>
                "#{inspect(reason)} (best-effort; member degrades to observe)."
            )

            :telemetry.execute(
              [:ezagent, :session, :participation_cap, :failed],
              %{count: 1},
              %{session_uri: session_uri, member_uri: member_uri, reason: reason}
            )

            :ok
        end
      end
    end)
  end

  defp grant_authorization(%URI{} = granter) do
    admin = Ezagent.Entity.User.admin_uri()

    if Ezagent.URI.stable_key(granter) == Ezagent.URI.stable_key(admin),
      do: {:admin, granter},
      else: {:held_by, granter}
  end

  # True iff `held` (the member's current caps) already contains a cap that
  # authorizes `behavior`.`action` on this session instance — same `matches?/2`
  # semantics the runtime step-5.5 check uses. Lets the mount/provision grants
  # be idempotent (no re-grant churn for admin's wildcard or an already-mounted
  # member).
  defp already_authorized?(held, behavior, action, session_uri, workspace_uri) do
    needed = %{
      kind: :session,
      behavior: behavior,
      action: action,
      instance: Ezagent.URI.instance(session_uri),
      workspace_uri: workspace_uri
    }

    held
    |> MemberCap.caps_to_list()
    |> Enum.any?(fn
      %Ezagent.Capability{} = cap -> Ezagent.Capability.matches?(cap, needed)
      _ -> false
    end)
  end
end
