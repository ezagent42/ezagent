defmodule Ezagent.Orchestrator.OwnerNotifier do
  @moduledoc """
  Best-effort owner notifications for a session's orchestrator Agent.

  Extracted from `EzagentDomainInstanceMessage.SessionCreator` (#154
  cleanup 2026-06-20) — a cohesive "surface an orchestrator degradation
  to the session owner" concern lifted out of the create/finalize path
  to keep `SessionCreator` under the architecture LOC/def-count caps,
  and co-located with the orchestrator's own home (`Ezagent.Orchestrator.*`,
  alongside the read-side `Ezagent.Orchestrator.Health` classifier) since
  it is an orchestrator concern, not a session-creation one.

  Two orthogonal degradations are surfaced (the orchestrator Agent is
  alive in BOTH cases — these are UX/reply degradations, not spawn
  failures):

  - **Role degraded** (`notify_role_degraded/4`, codex PR #408 HIGH-3,
    Invariant #9): the orchestrator's role-bootstrap (skill copy /
    CLAUDE.md hint) failed, so the agent will behave as a plain claude
    session.
  - **Credential stale** (`maybe_notify_credential_stale/4`, #17 (c)):
    the orchestrator's OAuth credential is stale, so the agent receives
    messages but replies 401 until the owner re-logs in.

  Both are BEST-EFFORT: only `entity://.../user/...` owners have an inbox,
  so non-user owners are logged-only; and a `Notifications.notify/2`
  failure is logged but never bubbles up (the orchestrator is alive
  regardless — this is the notification path failing, not the spawn).
  """

  require Logger

  @doc """
  Surface a DEGRADED orchestrator role-bootstrap to the session owner.

  codex PR #408 review HIGH-3 — the agent itself is alive; the
  orchestrator-specific UX is degraded. Best-effort: a notify failure
  logs but never bubbles up.
  """
  def notify_role_degraded(
        %URI{scheme: "entity"} = owner_uri,
        %URI{} = session_uri,
        %URI{} = orch_uri,
        degraded_meta
      ) do
    unless Ezagent.URI.type?(owner_uri, :user) do
      notify_role_degraded(:non_user_owner, session_uri, orch_uri, degraded_meta)
    else
      reason = Map.get(degraded_meta, :role_degraded_reason)

      Logger.warning(
        "Ezagent.Orchestrator.OwnerNotifier (session create):orchestrator role-bootstrap DEGRADED for " <>
          "session=#{URI.to_string(session_uri)} orchestrator=#{URI.to_string(orch_uri)} " <>
          "reason=#{inspect(reason)} — the agent is alive but the " <>
          "ezagent-session-orchestrator skill / CLAUDE.md hint did not load. " <>
          "The session owner has been notified (Invariant #9)."
      )

      try do
        _ =
          Ezagent.Notifications.notify(owner_uri, %{
            type: :orchestrator_recipe_degraded,
            body: %{
              text:
                "Orchestrator agent started but the orchestrator skill failed to load. " <>
                  "It will behave as a plain claude session. " <>
                  "Reason: #{inspect(reason)}",
              session_uri: session_uri,
              orchestrator_uri: orch_uri,
              reason: inspect(reason)
            },
            source: __MODULE__
          })
      rescue
        error ->
          Logger.warning(
            "Ezagent.Orchestrator.OwnerNotifier (session create):notify(:orchestrator_recipe_degraded) to " <>
              "#{URI.to_string(owner_uri)} raised #{inspect(error)} — the orchestrator " <>
              "is still alive; this is the notification path failing, not the spawn."
          )
      end

      :ok
    end
  end

  # Non-user owner (e.g. system principal or agent) — no inbox to notify.
  def notify_role_degraded(_owner, %URI{} = session_uri, %URI{} = orch_uri, meta) do
    reason = Map.get(meta, :role_degraded_reason)

    Logger.warning(
      "Ezagent.Orchestrator.OwnerNotifier (session create):orchestrator role-bootstrap DEGRADED for " <>
        "session=#{URI.to_string(session_uri)} orchestrator=#{URI.to_string(orch_uri)} " <>
        "reason=#{inspect(reason)} — owner is not a user URI; no inbox notification sent."
    )

    :ok
  end

  @doc """
  Surface a STALE OAuth credential to the session owner (#17 (c)) — a
  re-login reminder, on the same best-effort owner-notification path as
  `notify_role_degraded/4`.

  The orchestrator Agent is alive but will reply 401 until the owner
  re-logs in (`claude /login`). Only fires when the spawn meta carries
  `credential_stale: true`.
  """
  def maybe_notify_credential_stale(
        owner_uri,
        %URI{} = session_uri,
        %URI{} = orch_uri,
        %{credential_stale: true} = meta
      ) do
    notify_credential_stale(owner_uri, session_uri, orch_uri, meta)
  end

  def maybe_notify_credential_stale(_owner, _session, _orch, _meta), do: :ok

  defp notify_credential_stale(
         %URI{scheme: "entity"} = owner_uri,
         %URI{} = session_uri,
         %URI{} = orch_uri,
         meta
       ) do
    unless Ezagent.URI.type?(owner_uri, :user) do
      notify_credential_stale(:non_user_owner, session_uri, orch_uri, meta)
    else
      reason = Map.get(meta, :credential_stale_reason)

      Logger.warning(
        "Ezagent.Orchestrator.OwnerNotifier (session create):orchestrator OAuth credential #{inspect(reason)} for " <>
          "session=#{URI.to_string(session_uri)} orchestrator=#{URI.to_string(orch_uri)} — " <>
          "the agent is alive but will reply 401 until re-login. The session owner has been notified (#17 c)."
      )

      try do
        _ =
          Ezagent.Notifications.notify(owner_uri, %{
            type: :orchestrator_credential_stale,
            body: %{
              text:
                "Orchestrator agent's Claude login is #{reason} — it will receive messages " <>
                  "but cannot reply until you re-login (`claude /login` in its config dir).",
              session_uri: session_uri,
              orchestrator_uri: orch_uri,
              reason: inspect(reason)
            },
            source: __MODULE__
          })
      rescue
        error ->
          Logger.warning(
            "Ezagent.Orchestrator.OwnerNotifier (session create):notify(:orchestrator_credential_stale) to " <>
              "#{URI.to_string(owner_uri)} raised #{inspect(error)} — the orchestrator " <>
              "is still alive; this is the notification path failing, not the spawn."
          )
      end

      :ok
    end
  end

  defp notify_credential_stale(_owner, %URI{} = session_uri, %URI{} = orch_uri, meta) do
    reason = Map.get(meta, :credential_stale_reason)

    Logger.warning(
      "Ezagent.Orchestrator.OwnerNotifier (session create):orchestrator OAuth credential #{inspect(reason)} for " <>
        "session=#{URI.to_string(session_uri)} orchestrator=#{URI.to_string(orch_uri)} " <>
        "— owner is not a user URI; no inbox notification sent."
    )

    :ok
  end
end
