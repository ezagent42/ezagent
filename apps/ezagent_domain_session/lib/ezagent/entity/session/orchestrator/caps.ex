defmodule Ezagent.Entity.Session.Orchestrator.Caps do
  @moduledoc false

  # grant_orchestrator_scoped_caps  (2026-05-31 §4 step 6; codex rev-2
  # HIGH-1 idempotency)
  # ─────────────────────────────────────────────────────────────────────

  @doc """
  Issue the orchestrator's scope-bounded delegation artifacts and hand them
  to the orchestrator for self-storage. If the owner holds the required
  Template authority, the same flow includes the delegable Template caps.

  RFC #402 (Allen 2026-05-26): caps #1–#4 go TO the orchestrator. The
  workspace is derived from the session's `WorkspaceRegistry` binding
  (set by the atomic create before this runs).

  2026-05-31 orchestrator-startup-atomicity §4 step 6 — made public +
  the owner `OrchestratorAdmin :restart` grant was split OUT (it now
  lives in `EzagentDomainInstanceMessage.SessionCreator.create_session/3`, the single chokepoint,
  using the named `cap_equal_ignoring_metadata?/2`). This function
  grants ONLY the orchestrator-side caps.

  Idempotent: a repeated handoff of a logically-equal cap is skipped via
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
    # This reconciliation runs immediately after materialization, while the
    # transport may still be settling. Read the Identity slice directly so
    # deciding what to issue never dispatches through the readiness gate.
    current = Ezagent.EntityCaps.load(orchestrator_uri)

    {genesis_caps, rule_caps} =
      desired
      |> Enum.split_with(&orchestrator_delegation_cap?/1)

    to_grant =
      rule_caps
      |> Enum.filter(&Ezagent.ActionSet.IdentityAdmin.rule_cap_bounded?/1)
      |> Kernel.++(genesis_caps)
      |> Enum.reject(fn want ->
        Enum.any?(current, &cap_equal_ignoring_metadata?(&1, want))
      end)

    with {:ok, issued} <- issue_scoped_caps(orchestrator_uri, owner_uri, to_grant),
         :ok <- absorb_scoped_caps(orchestrator_uri, issued) do
      :ok
    else
      {:error, reason} -> {:error, {:scoped_cap_grant_failed, reason}}
    end
  end

  # Authorize the complete desired set before the first artifact is handed to
  # the grantee. This preserves all-or-nothing ISSUE ordering even though
  # self-storage itself is deliberately fire-and-forget.
  defp issue_scoped_caps(orchestrator_uri, owner_uri, caps) do
    target = Ezagent.URI.instance(orchestrator_uri)

    caps
    |> Enum.reduce_while({:ok, []}, fn cap, {:ok, issued} ->
      case Ezagent.Cap.issue(grant_tag_for(cap, owner_uri), target, cap) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | issued]}}
        {:error, reason} -> {:halt, {:error, {:issue_failed, cap, reason}}}
      end
    end)
    |> case do
      {:ok, issued} -> {:ok, Enum.reverse(issued)}
      {:error, _reason} = error -> error
    end
  end

  defp absorb_scoped_caps(orchestrator_uri, issued) do
    Enum.reduce_while(issued, :ok, fn artifact, :ok ->
      case Ezagent.Identity.absorb_cap(orchestrator_uri, artifact) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:absorb_failed, artifact, reason}}}
      end
    end)
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

    desired
    |> Enum.filter(fn cap ->
      orchestrator_delegation_cap?(cap) or
        Ezagent.ActionSet.IdentityAdmin.rule_cap_bounded?(cap)
    end)
    |> Enum.each(fn cap ->
      _ = Ezagent.Identity.Grant.revoke_cap(orchestrator_uri, cap, grant_tag_for(cap, owner_uri))
    end)

    :ok
  end

  defp grant_tag_for(%Ezagent.Capability{} = cap, %URI{} = owner_uri) do
    if orchestrator_delegation_cap?(cap) do
      {:genesis, owner_uri}
    else
      tag_for_rule(owner_uri)
    end
  end

  # Authorization tag for retained rule-bounded template caps. Orchestrator's
  # two delegation caps are bounded by session/spawn lineage but intentionally
  # behavior-wildcard; those use the genesis fallback above without widening the
  # generic rule-grant predicate.
  defp tag_for_rule(%URI{} = owner_uri),
    do: {:rule, :template_materialize, owner_uri}

  defp orchestrator_delegation_cap?(%Ezagent.Capability{
         kind: kind,
         behavior: :any,
         action: :any,
         instance: instance
       })
       when kind in [:session, :agent] and
              (is_tuple(instance) and tuple_size(instance) == 2) do
    elem(instance, 0) in [:within_session, :spawned_by] and match?(%URI{}, elem(instance, 1))
  end

  defp orchestrator_delegation_cap?(_), do: false

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
    # Owner authority must come from the non-spoofable held-cap loader used by
    # `Cap.issue/3`, not from a readiness-gated call to the owner process.
    owner_caps = Ezagent.Identity.read_held_caps(owner_uri)

    workspace_name = Ezagent.URI.workspace_name!(session_workspace)

    candidates = [
      {:session_template, Ezagent.URI.template(workspace_name, :session, "_preflight@_")},
      {:agent_template, Ezagent.URI.template(workspace_name, :agent, :_preflight)}
    ]

    candidates
    |> Enum.filter(fn {kind, representative_uri} ->
      needed = %{
        kind: kind,
        behavior: Ezagent.ActionSet.Template,
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
        behavior: Ezagent.ActionSet.Template,
        action: :any,
        instance: {:within_workspace, session_workspace},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: nil
      }
    end)
  end
end
