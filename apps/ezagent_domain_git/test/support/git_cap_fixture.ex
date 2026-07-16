defmodule Ezagent.DomainGit.TestSupport.GitCapFixture do
  @moduledoc false

  alias Ezagent.{Cap, Capability, Invocation}

  @workspace_name "git-fixture"
  @task_access_id "task-7"

  def exact_task_cap(action) when is_atom(action) do
    workspace_uri = Ezagent.URI.workspace(@workspace_name)
    task_access_uri = Ezagent.URI.resource(@workspace_name, "git-task-access", @task_access_id)
    governance_uri = Ezagent.URI.entity(@workspace_name, "user", "governance")
    grantee_uri = Ezagent.URI.entity(@workspace_name, "agent", "task-worker")
    authorization = {:genesis, governance_uri}

    capability =
      Capability.cap(
        :resource,
        Ezagent.ActionSet.GitTaskAccess,
        action,
        Ezagent.URI.instance(task_access_uri),
        workspace_uri
      )

    {:ok, artifact} = Cap.issue(authorization, grantee_uri, capability)
    true = Cap.verify_for(artifact, grantee_uri)

    invocation = %Invocation{
      target: Ezagent.URI.with_action(task_access_uri, :git_task_access, action),
      mode: :call,
      args: %{},
      ctx: %{
        caller: grantee_uri,
        caps: MapSet.new([artifact]),
        reply: {:caller_inbox, self()}
      }
    }

    %{
      artifact: artifact,
      governance_uri: governance_uri,
      grantee_uri: grantee_uri,
      invocation: invocation,
      task_access_uri: task_access_uri,
      workspace_uri: workspace_uri
    }
  end
end
