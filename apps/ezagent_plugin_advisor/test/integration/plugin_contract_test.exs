defmodule EzagentPluginAdvisor.Integration.PluginContractTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{KindRegistry, TemplateRegistry, Workspace, WorkspaceRegistry}
  alias EzagentPluginAdvisor.Template.AdvisorSession

  test "advisor plugin registers a session.advisor Template Class" do
    assert EzagentPluginAdvisor.Application in Ezagent.PluginRegistry.list_all()

    info = Ezagent.PluginRegistry.info("advisor")
    assert info.slug == "advisor"
    assert info.name == "Advisor"

    assert EzagentPluginAdvisor.Application.template_classes() == [AdvisorSession]
    assert {:ok, AdvisorSession} = TemplateRegistry.lookup("session.advisor")
  end

  test "advisor session template validates its locked shape" do
    assert AdvisorSession.template_name() == "session.advisor"

    assert :ok =
             AdvisorSession.validate(%{
               "class" => "session.advisor",
               "session_name" => "main",
               "operator_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
             })

    assert {:error, :missing_session_name} =
             AdvisorSession.validate(%{"class" => "session.advisor"})

    assert {:error, :missing_operator_uri} =
             AdvisorSession.validate(%{
               "class" => "session.advisor",
               "session_name" => "main"
             })

    assert {:error, {:wrong_class, "session.generic"}} =
             AdvisorSession.validate(%{
               "class" => "session.generic",
               "session_name" => "main"
             })
  end

  test "Workspace.add_template instantiates an advisor SocialwareSession without core/domain edits" do
    workspace_name = "advisor-contract-#{System.unique_integer([:positive])}"
    session_name = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    session_uri = Ezagent.URI.session(workspace_name, :advisor, session_name)

    {:ok, _ws_pid} = Workspace.create(workspace_name, %{})

    assert :error = KindRegistry.lookup(session_uri)

    assert :ok =
             Workspace.add_template(workspace_name, "advisor-main", %{
               "class" => "session.advisor",
               "session_name" => session_name,
               "operator_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
             })

    assert {:ok, pid} = KindRegistry.lookup(session_uri)
    assert is_pid(pid)
    assert {:ok, ^workspace_uri} = WorkspaceRegistry.lookup(session_uri)

    assert {:ok, chat} = Ezagent.Kind.get_slice(session_uri, :chat)
    working_copy = Ezagent.Behavior.Chat.template_working_copy(chat)

    assert working_copy["class"] == "session.advisor"
    assert working_copy["vertical"] == "advisor"
    assert working_copy["node_types"] == EzagentPluginAdvisor.NodeTypes.node_types()
    assert working_copy["roles"] == EzagentPluginAdvisor.NodeTypes.default_roles()

    assert %{online: true, role_name: "operator", in_session_template: true} =
             Map.fetch!(chat.members, Ezagent.Entity.User.admin_uri())
  end
end
