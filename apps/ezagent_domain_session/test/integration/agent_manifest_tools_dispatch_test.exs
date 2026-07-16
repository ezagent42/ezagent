defmodule EzagentDomainSession.Integration.AgentManifestToolsDispatchTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.AgentManifest.Tools
  alias Ezagent.Entity.{Agent, Session}

  test "action tool dispatch is denied when the agent lacks an Identity-slice grant" do
    session_uri = Ezagent.URI.session("team-alpha", "generic", "manifest-tool-deny")
    agent_uri = Ezagent.URI.agent("team-alpha", "tool_runner_denied")
    workspace_uri = URI.new!("workspace://team-alpha")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent_uri, initial_caps: MapSet.new()})

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, workspace_uri)

    message = Ezagent.Message.new(agent_uri, %{text: "should not send"})

    tool = %{
      name: "send",
      type: :action,
      action: URI.to_string(Ezagent.URI.with_action(session_uri, :session, :send)),
      caps: [
        %{
          "kind" => "session",
          "behavior" => "Ezagent.ActionSet.Session",
          "action" => "send"
        }
      ],
      optional: false
    }

    assert {:error, :missing_cap} =
             Tools.dispatch_action(agent_uri, tool, %{message: message})
  end
end
