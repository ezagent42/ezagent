defmodule Ezagent.Message.ActionableErrorWorkflowTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Message.{ActionableError, ActionableErrorIssue}

  test "persisting an unclassified error registers one issue and notifies the operator" do
    suffix = System.unique_integer([:positive])
    workspace_name = "issue-#{suffix}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    session_uri = Ezagent.URI.session(workspace_name, "default", "main")
    agent_uri = Ezagent.URI.new!("entity://issue-#{suffix}/agent/curl")
    admin_uri = Ezagent.URI.user("system", "admin")

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
    :ok = Ezagent.Notifications.subscribe(admin_uri)

    message =
      Ezagent.Message.new(agent_uri, %{
        text: "unknown failure",
        attachments: [],
        actionable_error: ActionableError.new(:unknown, detail: "decode=:invalid_json")
      })

    assert {:ok, written} = Ezagent.MessageStore.write(message, session_uri)
    assert %ActionableErrorIssue{} = issue = ActionableErrorIssue.by_message_id(written.id)
    assert issue.code == "agent.unclassified_failure"
    assert issue.workspace_uri == URI.to_string(workspace_uri)
    assert issue.agent_uri == URI.to_string(agent_uri)
    assert issue.session_uri == URI.to_string(session_uri)
    assert issue.occurred_at == written.inserted_at

    ticket = ActionableErrorIssue.ticket(issue)

    assert_receive {:notification, ^admin_uri,
                    %{type: :actionable_error_issue_registered, body: %{ticket: ^ticket}}}

    assert {:ok, _same_message} = Ezagent.MessageStore.write(message, session_uri)
    assert ActionableErrorIssue.by_message_id(written.id).id == issue.id
    refute_receive {:notification, ^admin_uri, %{type: :actionable_error_issue_registered}}, 50
  end
end
