defmodule Ezagent.OwnerGatedWorkspace do
  @moduledoc """
  Owner-gated workspace-membership writes: session→workspace bind and agent
  lineage record.

  `Ezagent.WorkspaceRegistry.bind/2` and `Ezagent.AgentLineage.record/2` are
  workspace-bound side effects that plugins performed directly, bypassing the
  workspace owner gate. This is the core seam that asserts the current runtime
  owns the target workspace before delegating to the underlying write, giving a
  future distributed runtime one place to enforce "you may only bind into /
  record lineage in a workspace this runtime owns."

  On the owner path — and whenever the gate is in `:observe` mode — the result is
  byte-identical to calling the underlying function directly. An ENFORCED
  non-owner violation returns `{:error, {:not_workspace_owner, ...}}` (the gate's
  own violation term), never a new success shape.

  `bind/2` gates on the TARGET `workspace_uri` (the workspace being written into)
  via the STRICT `assert_local_owner/2`, mirroring
  `EzagentDomainInstanceMessage.SessionCreator`'s
  `assert_local_owner(workspace_uri, {:session_create, session_uri})`. Strict
  gating validates the arg is a real `workspace://` URI (a non-workspace or
  cross-workspace target is refused, not silently derived) — the session URI can
  carry a placeholder workspace segment (e.g. protocol_api's
  `session://system/generic/...`), so gating the session's structural workspace
  would check the wrong thing. `record_lineage/2` gates on the `agent_uri` via
  `assert_local_owner_for_uri/2` (the agent's own workspace is derived and is the
  subject of the write).
  """

  @doc """
  Owner-gate the target `workspace_uri`, then bind `session_uri` into it.

  Returns `:ok` on the owner/observe path (byte-identical to
  `Ezagent.WorkspaceRegistry.bind/2`), or `{:error, {:not_workspace_owner, ...}}`
  on an enforced non-owner violation.
  """
  @spec bind(URI.t() | String.t(), URI.t() | String.t()) :: :ok | {:error, term()}
  def bind(session_uri, workspace_uri) do
    with :ok <-
           Ezagent.WorkspaceOwnerGate.assert_local_owner(
             to_uri(workspace_uri),
             {:workspace_bind, session_uri}
           ) do
      Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    end
  end

  @doc """
  Owner-gate `agent_uri`'s workspace, then record its `spawned_by` lineage.

  Returns whatever `Ezagent.AgentLineage.record/2` returns on the owner/observe
  path, or `{:error, {:not_workspace_owner, ...}}` on an enforced non-owner
  violation.
  """
  @spec record_lineage(URI.t() | String.t(), URI.t() | String.t()) :: :ok | {:error, term()}
  def record_lineage(agent_uri, spawned_by) do
    with :ok <-
           Ezagent.WorkspaceOwnerGate.assert_local_owner_for_uri(
             to_uri(agent_uri),
             {:lineage_record, agent_uri}
           ) do
      Ezagent.AgentLineage.record(agent_uri, spawned_by)
    end
  end

  defp to_uri(%URI{} = uri), do: uri
  defp to_uri(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)
end
