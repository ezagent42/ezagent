defmodule Ezagent.DomainGit.TestSupport.GitCapFixture do
  @moduledoc false

  alias Ezagent.{Cap, Capability, Invocation}

  @workspace_name "git-fixture"
  @task_access_id "task-7"
  @actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews
  ]

  def exact_task_cap(action, options \\ []) when action in @actions and is_list(options) do
    options =
      Keyword.validate!(options,
        workspace_name: @workspace_name,
        task_access_id: @task_access_id,
        grantee_uri: nil
      )

    workspace_name = Keyword.fetch!(options, :workspace_name)
    task_access_id = Keyword.fetch!(options, :task_access_id)
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    task_access_uri = Ezagent.URI.resource(workspace_name, "git-task-access", task_access_id)

    grantee_uri =
      Keyword.get(options, :grantee_uri) ||
        Ezagent.URI.entity(workspace_name, "agent", "task-worker")

    if Ezagent.URI.entity_workspace_uri(grantee_uri) != workspace_uri do
      raise ArgumentError, "grantee_uri must belong to the fixture workspace"
    end

    admin_uri = Ezagent.URI.user(:system, :admin)
    authorization = {:held_by, admin_uri}

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
      governance_uri: admin_uri,
      grantee_uri: grantee_uri,
      invocation: invocation,
      task_access_uri: task_access_uri,
      workspace_uri: workspace_uri
    }
  end
end
