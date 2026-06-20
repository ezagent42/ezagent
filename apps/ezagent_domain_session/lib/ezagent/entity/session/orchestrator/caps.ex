defmodule Ezagent.Entity.Session.Orchestrator.Caps do
  @moduledoc false

  # grant_orchestrator_scoped_caps  (2026-05-31 §4 step 6; codex rev-2
  # HIGH-1 idempotency)
  # ─────────────────────────────────────────────────────────────────────

  @doc """
  Grant the orchestrator its scope-bounded delegation caps + (if the
  owner holds them) the delegable Template caps.

  RFC #402 (Allen 2026-05-26): caps #1–#4 go TO the orchestrator. The
  workspace is derived from the session's `WorkspaceRegistry` binding
  (set by the atomic create before this runs).

  2026-05-31 orchestrator-startup-atomicity §4 step 6 — made public +
  the owner `OrchestratorAdmin :restart` grant was split OUT (it now
  lives in `EzagentDomainInstanceMessage.SessionCreator.create_session/3`, the single chokepoint,
  using the named `cap_equal_ignoring_metadata?/2`). This function
  grants ONLY the orchestrator-side caps.

  Idempotent: a re-grant of a logically-equal cap is skipped via
  `cap_equal_ignoring_metadata?/2`.
  """
  @spec grant_orchestrator_scoped_caps(URI.t(), URI.t(), URI.t()) :: :ok | {:error, term()}
  def grant_orchestrator_scoped_caps(
        %URI{} = orchestrator_uri,
        %URI{} = session_uri,
        %URI{} = owner_uri
      ) do
    session_workspace =
      case Ezagent.WorkspaceRegistry.lookup(session_uri) do
        {:ok, ws} ->
          ws

        :error ->
          raise "session #{URI.to_string(session_uri)} has no workspace binding " <>
                  "— cannot derive workspace_uri for orchestrator scope caps"
      end

    do_grant_orchestrator_scoped_caps(
      orchestrator_uri,
      session_uri,
      owner_uri,
      session_workspace
    )
  end

  defp do_grant_orchestrator_scoped_caps(
         %URI{} = orchestrator_uri,
         %URI{} = session_uri,
         %URI{} = owner_uri,
         %URI{} = session_workspace
       ) do
    desired = build_desired_caps(orchestrator_uri, session_uri, owner_uri, session_workspace)
    current = Ezagent.Entity.Session.list_caps_for_materialization(orchestrator_uri)

    to_grant =
      Enum.reject(desired, fn want ->
        Enum.any?(current, &cap_equal_ignoring_metadata?(&1, want))
      end)

    # Grant chokepoint (SPEC 2026-06-17 §4 PR-2, site #7). This is a MIXED
    # cap set: caps #1/#2 are `behavior: :any` (NOT rule-bounded — they
    # need genesis/admin authority, like `grant_owner_orchestrator_manage_cap`)
    # while caps #3/#4 are `Template/{:within_workspace}` (rule-bounded).
    # `tag_for/2` selects the right authorization PER CAP — one shared tag
    # would be wrong for one half. `template-materialize` is no longer the
    # authorizer for either; entity `granted_by` is the session OWNER.
    results =
      Enum.map(to_grant, fn want ->
        Ezagent.Identity.Grant.grant_cap(orchestrator_uri, want, tag_for(want, owner_uri))
      end)

    case Enum.reject(results, &(&1 == :ok)) do
      [] -> :ok
      [err | _] -> {:error, {:scoped_cap_grant_failed, err}}
    end
  end

  @doc """
  Revoke the orchestrator's scope-bounded delegation caps — the exact
  cap set `grant_orchestrator_scoped_caps/3` adds.

  2026-05-31 orchestrator-startup-atomicity §4 step 9 (codex-review Q1)
  — the rollback inverse of the step-6 grant. Used by
  `EzagentDomainInstanceMessage.rollback_session/3` so a late create failure leaves
  NO scoped-cap residue on the orchestrator entity (in addition to the
  Kind teardown). Best-effort + idempotent: `:revoke_cap` matches by the
  cap identity-key (kind/behavior/instance/workspace_uri), so revoking
  an absent cap is a clean no-op. A dispatch failure is swallowed (the
  orchestrator Kind + its `:identity` snapshot are torn down anyway —
  this is belt-and-suspenders for the durable `caps_json` projection).

  `workspace_uri` is taken explicitly (not via `WorkspaceRegistry`)
  because the binding may already have been unbound by the time rollback
  reaches this step.
  """
  @spec revoke_orchestrator_scoped_caps(URI.t(), URI.t(), URI.t(), URI.t()) :: :ok
  def revoke_orchestrator_scoped_caps(
        %URI{} = orchestrator_uri,
        %URI{} = session_uri,
        %URI{} = owner_uri,
        %URI{} = workspace_uri
      ) do
    desired = build_desired_caps(orchestrator_uri, session_uri, owner_uri, workspace_uri)

    # Grant chokepoint (SPEC 2026-06-17 §4 PR-2, site #14 — the rollback
    # revoke twin of site #7). Same MIXED cap set, so the SAME per-cap
    # `tag_for/2` selection: caps #1/#2 revoke under `{:genesis, …}`
    # (pass dispatch step 5.5 via the genesis wildcard), caps #3/#4 under
    # `{:rule, …}`. `template-materialize` is no longer the authorizer.
    Enum.each(desired, fn cap ->
      _ = Ezagent.Identity.Grant.revoke_cap(orchestrator_uri, cap, tag_for(cap, owner_uri))
    end)

    :ok
  end

  # Per-cap authorization-tag selection (SPEC 2026-06-17 §4 PR-2, sites
  # #7/#14). The orchestrator scoped-cap set is heterogeneous:
  #
  #   * caps #1/#2 (`session/:any/{:within_session}`,
  #     `agent/:any/{:spawned_by}`) carry `behavior: :any`, which
  #     `IdentityAdmin.rule_cap_bounded?/1` REJECTS (a rule may not mint a
  #     cross-behavior wildcard — §3.3). `IdentityAdmin.check_grant_authorized`
  #     routes a `behavior: :any` cap through `require_workspace_admin`, so
  #     they genuinely need genesis/admin authority → `{:system, bootstrap,
  #     owner}` (Decision #154's extreme fallback; governed by
  #     `no_wildcard_system_principals_test`, NOT `no_unowned`). This is the
  #     identical shape `grant_owner_orchestrator_manage_cap/2` already routes
  #     through bootstrap. (NOTE: SPEC §4 said "cap#2 qualifies via rule" —
  #     that is an authoring error; cap#2's `behavior: :any` is rule-ineligible
  #     by §3.3. Code wins.)
  #   * caps #3/#4 (`<*_template>/Template/:any/{:within_workspace}`) are
  #     concrete kind + behavior + scope-bounded instance → rule-bounded →
  #     `{:rule, :template_materialize, owner}`.
  #
  # `granted_by` is the session OWNER in both branches (the tag derives it).
  defp tag_for(%Ezagent.Capability{} = cap, %URI{} = owner_uri) do
    if Ezagent.Behavior.IdentityAdmin.rule_cap_bounded?(cap) do
      {:rule, :template_materialize, owner_uri}
    else
      # #154 genesis collapse (2026-06-20) — the genesis wildcard authorizer
      # is now the canonical admin-granted cap, supplied by `{:genesis, …}`;
      # the eliminated `{:system, bootstrap, owner}` tag is gone.
      {:genesis, owner_uri}
    end
  end

  defp build_desired_caps(
         %URI{} = orchestrator_uri,
         %URI{} = session_uri,
         %URI{} = owner_uri,
         %URI{} = session_workspace
       ) do
    # Cap #1 + #2 — unconditional scope-bounded delegation.
    # SPEC 2026-05-27 capability-action-axis — orchestrator delegation
    # is intentionally broad within the bounded scope (within-session
    # for Cap #1, spawned-by for Cap #2). `action: :any` matches the
    # `behavior: :any` axis — symmetric wildcard. The bound is the
    # instance scope tuple, not the action narrowing.
    unconditional = [
      %Ezagent.Capability{
        kind: :session,
        behavior: :any,
        action: :any,
        instance: {:within_session, session_uri},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: nil
      },
      %Ezagent.Capability{
        kind: :agent,
        behavior: :any,
        action: :any,
        instance: {:spawned_by, orchestrator_uri},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: nil
      }
    ]

    # Caps #3/#4 — gated by owner-cap preflight (§1.4).
    template_caps = delegable_template_caps(owner_uri, session_workspace)

    unconditional ++ template_caps
  end

  @doc """
  PR-A helper (SPEC §5, codex rev-2 HIGH-1) — logical-equality
  predicate for capabilities, IGNORING `granted_at` (a per-dispatch
  timestamp).

  The IDENTITY of a cap is `{kind, behavior, instance, workspace_uri,
  granted_by}` — the authority being granted + WHO granted it. The
  WHEN is metadata; the same authority granted twice should be a
  no-op, NOT two distinct rows in the cap MapSet (which would burden
  the audit log + grow the User snapshot on every reconciler re-run).
  """
  @spec cap_equal_ignoring_metadata?(Ezagent.Capability.t(), Ezagent.Capability.t()) ::
          boolean()
  def cap_equal_ignoring_metadata?(%Ezagent.Capability{} = a, %Ezagent.Capability{} = b) do
    # SPEC 2026-05-27 capability-action-axis — include action axis in
    # logical equality via `action_of/1` for snapshot-restored
    # old-shape tolerance.
    a.kind == b.kind and
      a.behavior == b.behavior and
      Ezagent.Capability.action_of(a) == Ezagent.Capability.action_of(b) and
      a.instance == b.instance and
      a.workspace_uri == b.workspace_uri and
      a.granted_by == b.granted_by
  end

  # ─────────────────────────────────────────────────────────────────────

  # Owner-cap preflight for caps #3 and #4  (KEPT verbatim — round-1 §1.4)
  # ─────────────────────────────────────────────────────────────────────

  defp delegable_template_caps(%URI{} = owner_uri, %URI{} = session_workspace) do
    owner_caps = Ezagent.Entity.Session.list_caps_for_materialization(owner_uri)

    workspace_name = Ezagent.URI.workspace_name!(session_workspace)

    candidates = [
      {:session_template, Ezagent.URI.template(workspace_name, :session, "_preflight@_")},
      {:agent_template, Ezagent.URI.template(workspace_name, :agent, :_preflight)}
    ]

    candidates
    |> Enum.filter(fn {kind, representative_uri} ->
      needed = %{
        kind: kind,
        behavior: Ezagent.Behavior.Template,
        # SPEC 2026-05-27 capability-action-axis — orchestrator
        # template delegation spans `:read`, `:write`, `:instantiate`,
        # `:fork` (Tools.update_agent_template + save_template_as +
        # fork + Generator instantiate). Bound by instance scope
        # `:within_workspace`; action axis stays `:any` so orchestrator
        # tooling works without one cap per action.
        action: :any,
        instance: representative_uri,
        workspace_uri: session_workspace
      }

      Enum.any?(owner_caps, &Ezagent.Capability.matches?(&1, needed))
    end)
    |> Enum.map(fn {kind, _representative_uri} ->
      %Ezagent.Capability{
        kind: kind,
        behavior: Ezagent.Behavior.Template,
        action: :any,
        instance: {:within_workspace, session_workspace},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: nil
      }
    end)
  end
end
