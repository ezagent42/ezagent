defmodule EzagentPluginGitWorkflow.ReadyWorkspaceProbe do
  @moduledoc """
  A workspace provisioning + change-collection stand-in that answers with the
  SHAPE the real task-workspace provisioner answers with — including
  `resolved_base_commit` and `start_token`.

  `Ezagent.DomainGit.TestSupport.WorkspaceProvisionProbe` answers
  `%{provision_id:, status:}` only, which is all its own suite needs. The
  Slice P4c runner reads `resolved_base_commit` (design §6.1's
  `expected_base_sha`) and must be proven NOT to persist `start_token`, so a
  probe that omits both cannot exercise either claim. This one mirrors
  `Ezagent.Workspace.TaskWorkspace.Provisioner`'s `ready_result/1` field for
  field rather than inventing a shape.

  Both answers are pure functions of the request, so a repeated provision or a
  repeated collection returns identical values — which is what lets the
  idempotency assertions mean something. Failure injection deliberately does
  NOT live here: the handler runs inside the task-access Kind's process, not
  the test's, so a per-process switch would be invisible to it, and the
  failure-path claims are made against the scripted seam instead, where the
  runner's own behaviour is what is under examination.
  """

  @behaviour Ezagent.DomainGit.WorkspaceProvisionPort
  @behaviour Ezagent.DomainGit.WorkspaceChangePort

  alias Ezagent.DomainGit.FileChange

  @base_commit String.duplicate("d", 40)
  @start_token "PROBE-START-TOKEN-MUST-NOT-PERSIST"

  @doc "The `resolved_base_commit` every ready answer carries."
  def base_commit, do: @base_commit

  @doc "The `start_token` every ready answer carries — nothing may persist it."
  def start_token, do: @start_token

  @impl Ezagent.DomainGit.WorkspaceProvisionPort
  def prepare(request) do
    {:ok,
     %{
       status: :ready,
       provision_id: request.provision_id,
       task_access_uri: request.task_access_uri,
       task_uri: request.task_uri,
       generation: request.generation,
       cwd: "/tmp/ezagent-p4c/" <> request.provision_id,
       resolved_base_commit: @base_commit,
       local_branch_ref: "refs/heads/probe",
       start_token: @start_token
     }}
  end

  @impl Ezagent.DomainGit.WorkspaceProvisionPort
  def cleanup(request), do: {:ok, %{provision_id: request.provision_id, status: :cleaned}}

  @impl Ezagent.DomainGit.WorkspaceChangePort
  def collect(request) do
    {:ok, change} =
      FileChange.new(%{
        path: "p4c.txt",
        operation: :upsert,
        content: "collected for " <> request.provision_id
      })

    {:ok, [change]}
  end
end
