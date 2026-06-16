defmodule EzagentPluginLoom.Integration.PluginContractTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{KindRegistry, TemplateRegistry, Workspace, WorkspaceRegistry}
  alias EzagentPluginLoom.Template.LoomSession

  test "loom plugin registers a session.loom Template Class" do
    assert EzagentPluginLoom.Application in Ezagent.PluginRegistry.list_all()

    info = Ezagent.PluginRegistry.info("loom")
    assert info.slug == "loom"
    assert info.name == "Loom"

    assert EzagentPluginLoom.Application.template_classes() == [LoomSession]
    assert {:ok, LoomSession} = TemplateRegistry.lookup("session.loom")
  end

  test "loom session template validates its locked shape" do
    assert LoomSession.template_name() == "session.loom"

    assert :ok =
             LoomSession.validate(%{
               "class" => "session.loom",
               "session_name" => "main",
               "operator_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
             })

    assert {:error, :missing_session_name} =
             LoomSession.validate(%{"class" => "session.loom"})

    assert {:error, :missing_operator_uri} =
             LoomSession.validate(%{
               "class" => "session.loom",
               "session_name" => "main"
             })

    assert {:error, {:wrong_class, "session.generic"}} =
             LoomSession.validate(%{
               "class" => "session.generic",
               "session_name" => "main"
             })
  end

  test "Workspace.add_template instantiates a loom session (unified Entity.Session) without core/domain edits" do
    workspace_name = "loom-contract-#{System.unique_integer([:positive])}"
    session_name = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    session_uri = Ezagent.URI.session(workspace_name, :loom, session_name)

    {:ok, _ws_pid} = Workspace.create(workspace_name, %{})

    assert :error = KindRegistry.lookup(session_uri)

    assert :ok =
             Workspace.add_template(workspace_name, "loom-main", %{
               "class" => "session.loom",
               "session_name" => session_name,
               "operator_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
             })

    assert {:ok, pid} = KindRegistry.lookup(session_uri)
    assert is_pid(pid)
    assert {:ok, ^workspace_uri} = WorkspaceRegistry.lookup(session_uri)

    assert {:ok, chat} = Ezagent.Kind.get_slice(session_uri, :session)
    working_copy = Ezagent.Behavior.Session.template_working_copy(chat)

    assert working_copy["class"] == "session.loom"
    assert working_copy["vertical"] == "loom"
    assert working_copy["node_types"] == EzagentPluginLoom.NodeTypes.node_types()
    assert working_copy["roles"] == EzagentPluginLoom.NodeTypes.default_roles()

    assert %{online: true, role_name: "operator", in_session_template: true} =
             Map.fetch!(chat.members, Ezagent.Entity.User.admin_uri())
  end
end
