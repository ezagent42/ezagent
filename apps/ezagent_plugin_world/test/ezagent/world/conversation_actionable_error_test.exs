defmodule Ezagent.World.ConversationActionableErrorTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Message.ActionableError
  alias Ezagent.World.{ConversationActions, ConversationData}

  test "message rows project structured actionable errors without parsing fallback prose" do
    sender = Ezagent.URI.new!("entity://team-alpha/agent/curl")
    error = ActionableError.new(:network_timeout, detail: "timeout=15000ms")

    message =
      Ezagent.Message.new(
        sender,
        %{
          text: "upstream API error: timeout",
          attachments: [],
          actionable_error: error
        },
        id: "failure-row"
      )

    row = ConversationData.message_row(message)

    assert row["text"] == "upstream API error: timeout"
    assert row["actionable_error"] == error
    assert row["actionable_error"]["code"] == "agent.network_timeout"
  end

  test "API key failures project direct repair for admins and a founder reminder for members" do
    suffix = System.unique_integer([:positive])
    workspace_name = "repair-projection-#{suffix}"
    workspace_uri = Ezagent.URI.new!("workspace://#{workspace_name}")
    founder = Ezagent.URI.new!("entity://#{workspace_name}/user/founder")
    member = Ezagent.URI.new!("entity://#{workspace_name}/user/member")
    agent = Ezagent.URI.new!("entity://#{workspace_name}/agent/curl")
    repair_href = "/world/agents/curl?tab=api-keys"

    assert {:ok, _workspace} =
             Ezagent.Workspace.Store.create(workspace_name, %{
               members: [founder, member],
               created_by: founder
             })

    message =
      Ezagent.Message.new(agent, %{
        text: "missing credentials",
        attachments: [],
        actionable_error: ActionableError.new(:missing_credentials, action_href: repair_href)
      })

    member_row =
      ConversationData.message_row(message, %{
        caller_uri: member,
        caller_caps: MapSet.new(),
        workspace_uri: workspace_uri
      })

    assert %{
             "layer" => 2,
             "repair_owner" => %{"uri" => founder_uri},
             "action" => %{"kind" => "notify_admin"}
           } = member_row["actionable_error"]

    assert founder_uri == URI.to_string(founder)
    refute Map.has_key?(member_row["actionable_error"]["action"], "href")

    admin_row =
      ConversationData.message_row(message, %{
        caller_uri: Ezagent.Entity.User.admin_uri(),
        caller_caps: MapSet.new(),
        workspace_uri: workspace_uri
      })

    assert admin_row["actionable_error"]["layer"] == 1
    assert admin_row["actionable_error"]["action"]["href"] == repair_href
  end

  test "member reminder delivers the founder a complete repair notification" do
    suffix = System.unique_integer([:positive])
    workspace_name = "repair-notify-#{suffix}"
    workspace_uri = Ezagent.URI.new!("workspace://#{workspace_name}")
    session_uri = Ezagent.URI.new!("session://#{workspace_name}/default/main")
    founder = Ezagent.URI.new!("entity://#{workspace_name}/user/founder")
    member = Ezagent.URI.new!("entity://#{workspace_name}/user/member")
    agent = Ezagent.URI.new!("entity://#{workspace_name}/agent/curl")
    repair_href = "/world/agents/curl?tab=api-keys"

    assert {:ok, _workspace} =
             Ezagent.Workspace.Store.create(workspace_name, %{
               members: [founder, member],
               created_by: founder
             })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
    :ok = Ezagent.Notifications.subscribe(founder)

    message =
      Ezagent.Message.new(agent, %{
        text: "missing credentials",
        attachments: [],
        actionable_error: ActionableError.new(:missing_credentials, action_href: repair_href)
      })

    assert {:ok, written} = Ezagent.MessageStore.write(message, session_uri)

    socket =
      build_socket(
        current_entity_uri: member,
        current_workspace_uri: workspace_uri,
        current_caps: MapSet.new()
      )

    assert {:noreply, socket} =
             ConversationActions.notify_error_admin(socket, session_uri, written.id)

    assert socket.assigns.last_dispatch_status == "ok:error_reminder_sent"

    assert_receive {:notification, ^founder,
                    %{type: :agent_repair_requested, body: notification_body}}

    assert notification_body.workspace_uri == URI.to_string(workspace_uri)
    assert notification_body.agent_uri == URI.to_string(agent)
    assert notification_body.error_code == "agent.credentials_missing"
    assert notification_body.requested_by == URI.to_string(member)
    assert notification_body.repair_href == repair_href

    admin_socket =
      build_socket(
        current_entity_uri: Ezagent.Entity.User.admin_uri(),
        current_workspace_uri: workspace_uri,
        current_caps: MapSet.new()
      )

    assert {:noreply, admin_socket} =
             ConversationActions.notify_error_admin(admin_socket, session_uri, written.id)

    assert admin_socket.assigns.last_dispatch_status == "error:not_allowed"
    [request] = Ezagent.Message.ActionableErrorRepairRequest.list_for_agent(agent)
    assert request.status == "open"

    :ok = Ezagent.Notifications.subscribe(member)

    assert {:ok, 1} =
             Ezagent.Message.ActionableErrorRepairRequest.complete_for_agent(
               agent,
               founder,
               "Founder Chen"
             )

    assert_receive {:notification, ^member,
                    %{type: :agent_repair_completed, body: completion_body}}

    assert completion_body.agent_uri == URI.to_string(agent)
    assert completion_body.error_code == "agent.credentials_missing"
    assert completion_body.repaired_by_name == "Founder Chen"
    assert completion_body.text =~ "Founder Chen"
    assert completion_body.repaired_by == URI.to_string(founder)

    [completed_request] =
      Ezagent.Message.ActionableErrorRepairRequest.list_for_agent(agent)

    assert completed_request.status == "completed"
    assert %DateTime{} = completed_request.completed_at
  end

  test "persisted unclassified failures show the automatic issue registration number" do
    suffix = System.unique_integer([:positive])
    workspace_name = "issue-row-#{suffix}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    session_uri = Ezagent.URI.session(workspace_name, "default", "main")
    agent = Ezagent.URI.new!("entity://issue-row-#{suffix}/agent/curl")

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)

    message =
      Ezagent.Message.new(agent, %{
        text: "unknown failure",
        attachments: [],
        actionable_error: ActionableError.new(:unknown, detail: "decode=:invalid_json")
      })

    assert {:ok, written} = Ezagent.MessageStore.write(message, session_uri)
    row = ConversationData.message_row(written)
    ticket = row["actionable_error"]["ticket"]

    assert ticket =~ "#"
    assert row["actionable_error"]["layer"] == 3
    assert row["actionable_error"]["next_step"] =~ "已自动登记"
    assert row["actionable_error"]["next_step"] =~ ticket
  end

  defp build_socket(assigns) do
    Enum.reduce(assigns, %Phoenix.LiveView.Socket{}, fn {key, value}, socket ->
      Phoenix.Component.assign(socket, key, value)
    end)
  end
end
