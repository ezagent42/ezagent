defmodule EzagentDomainInstanceMessage do
  @moduledoc """
  Public facade for the instance-message domain.

  Session creation is intentionally not exported here. Operator and user
  surfaces must call `Ezagent.Workspace.create_session/3`; the lower-level
  materializer lives in `EzagentDomainInstanceMessage.SessionCreator` as an
  internal implementation detail.
  """

  alias EzagentDomainInstanceMessage.SessionCreator

  @doc "Re-materialize a session's orchestrator agent, deriving the workspace from the session's binding. Delegates to `SessionCreator`."
  defdelegate repair_orchestrator(session_uri), to: SessionCreator

  @doc "Re-materialize a session's orchestrator agent with an explicit `workspace_uri` (for when the binding is unavailable). Delegates to `SessionCreator`."
  defdelegate repair_orchestrator(session_uri, workspace_uri), to: SessionCreator

  @doc "Tear down a partially-created session + its orchestrator (the create rollback inverse). Delegates to `SessionCreator`."
  defdelegate rollback_session(session_uri, orchestrator_uri), to: SessionCreator

  @doc "Tear down a partially-created session + orchestrator with `opts` (e.g. an explicit workspace when the binding is already unbound). Delegates to `SessionCreator`."
  defdelegate rollback_session(session_uri, orchestrator_uri, opts), to: SessionCreator

  @doc "Materialize a session's relay team (members + routing) from validated template `content`, granted by `granted_by`. Delegates to `SessionCreator`."
  defdelegate materialize_template_team(session_uri, workspace_uri, granted_by, content),
    to: SessionCreator

  @doc "Compute the deterministic instance name for a spawned team member from `(flavor, source_template_uri, role_name, session_uri)`. Exposed for callers/tests. Delegates to `SessionCreator`."
  defdelegate spawned_member_instance_name_public(
                flavor,
                source_template_uri,
                role_name,
                session_uri
              ),
              to: SessionCreator

  @doc "A stable short discriminator for a session (lowercase hex of the SHA-256 of its URI, truncated). Delegates to `SessionCreator`."
  defdelegate session_discriminator(session_uri), to: SessionCreator

  @doc "List all sessions. Delegates to `SessionCreator`."
  defdelegate list_sessions(), to: SessionCreator

  @doc "List sessions in `workspace_uri`. Delegates to `SessionCreator`."
  defdelegate list_sessions(workspace_uri), to: SessionCreator

  @doc "List sessions in `workspace_uri` filtered to those where `caller_uri` is a member (membership-only — no admin bypass). Delegates to `SessionCreator`."
  defdelegate list_sessions(workspace_uri, caller_uri), to: SessionCreator

  @doc "Live + durably-persisted sessions in `workspace_uri` (world UI listing; survives cold restart)."
  defdelegate list_persisted_sessions(workspace_uri), to: SessionCreator

  @doc "Return live sessions whose membership includes `agent_uri`. Delegates to `SessionCreator`."
  defdelegate agent_live_sessions(agent_uri), to: SessionCreator

  @doc "True when `agent_uri` is a member of at least one live session. Delegates to `SessionCreator`."
  defdelegate agent_in_live_session?(agent_uri), to: SessionCreator
end
