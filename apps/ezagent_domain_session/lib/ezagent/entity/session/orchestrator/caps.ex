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
    desired = build_desired_caps(session_uri, session_workspace)
    # This reconciliation runs immediately after materialization, while the
    # transport may still be settling. Read the Identity slice directly so
    # deciding what to issue never dispatches through the readiness gate.
    current = Ezagent.EntityCaps.load(orchestrator_uri)

    to_grant =
      desired
      |> Enum.reject(fn want ->
        Enum.any?(current, &cap_equal_ignoring_metadata?(&1, want))
      end)

    with :ok <- Ezagent.Identity.TargetAuthority.ensure(owner_uri, session_uri),
         {:ok, issued} <- issue_scoped_caps(orchestrator_uri, owner_uri, session_uri, to_grant),
         :ok <- absorb_scoped_caps(orchestrator_uri, issued) do
      :ok
    else
      {:error, reason} -> {:error, {:scoped_cap_grant_failed, reason}}
    end
  end

  # Authorize the complete desired set before the first artifact is handed to
  # the grantee. This preserves all-or-nothing ISSUE ordering even though
  # self-storage itself is deliberately fire-and-forget.
  defp issue_scoped_caps(orchestrator_uri, owner_uri, session_uri, caps) do
    caps
    |> Enum.reduce_while({:ok, []}, fn cap, {:ok, issued} ->
      authorization = grant_tag_for(cap, owner_uri, session_uri)

      case Ezagent.Cap.issue(authorization, orchestrator_uri, cap) do
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
    desired = build_desired_caps(session_uri, workspace_uri)

    desired
    |> Enum.each(fn cap ->
      _ =
        Ezagent.Identity.Grant.revoke_cap(
          orchestrator_uri,
          cap,
          grant_tag_for(cap, owner_uri, session_uri)
        )
    end)

    :ok
  end

  defp grant_tag_for(%Ezagent.Capability{instance: %URI{} = target}, owner_uri, session_uri) do
    if same_uri?(target, session_uri) do
      if same_uri?(owner_uri, Ezagent.Entity.User.admin_uri()),
        do: {:admin, owner_uri},
        else: {:held_by, owner_uri}
    else
      {:admin, Ezagent.Entity.User.admin_uri()}
    end
  end

  defp build_desired_caps(%URI{} = session_uri, %URI{} = session_workspace) do
    session_caps =
      Ezagent.CapabilityRegistry.subjects_for_kind(Ezagent.Entity.Session)
      |> Enum.reject(&Ezagent.Cap.Verifier.non_cap_action?(&1.behavior, &1.action))
      |> Enum.map(fn subject ->
        Ezagent.Capability.cap(
          :session,
          subject.behavior,
          subject.action,
          session_uri,
          session_workspace
        )
      end)

    workspace_caps =
      for action <- [:list_agent_templates, :list_session_templates, :write_session_templates] do
        Ezagent.Capability.cap(
          :workspace,
          Ezagent.ActionSet.Workspace,
          action,
          session_workspace,
          session_workspace
        )
      end

    session_caps ++ workspace_caps
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

  defp same_uri?(%URI{} = left, %URI{} = right) do
    Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
  end
end
