defmodule EzagentDomainInstanceMessage do
  @moduledoc """
  Public facade for the instance-message domain.

  Session creation is intentionally not exported here. Operator and user
  surfaces must call `Ezagent.Workspace.create_session/3`; the lower-level
  materializer lives in `EzagentDomainInstanceMessage.SessionCreator` as an
  internal implementation detail.
  """

  alias EzagentDomainInstanceMessage.SessionCreator

  defdelegate repair_orchestrator(session_uri), to: SessionCreator
  defdelegate repair_orchestrator(session_uri, workspace_uri), to: SessionCreator
  defdelegate rollback_session(session_uri, orchestrator_uri), to: SessionCreator
  defdelegate rollback_session(session_uri, orchestrator_uri, opts), to: SessionCreator

  defdelegate materialize_template_team(session_uri, workspace_uri, granted_by, content),
    to: SessionCreator

  defdelegate spawned_member_instance_name_public(
                flavor,
                source_template_uri,
                role_name,
                session_uri
              ),
              to: SessionCreator

  defdelegate session_discriminator(session_uri), to: SessionCreator
  defdelegate list_sessions(), to: SessionCreator
  defdelegate list_sessions(workspace_uri), to: SessionCreator
end
