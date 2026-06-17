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

  test "session.loom is selectable in the admin add-template dropdown (implements UI.Form)" do
    # 回归:list_form_classes/0 只收录实现了 Ezagent.UI.Form 的 class;早期 LoomSession
    # 没实现 → admin /workspaces add-template 下拉看不到 session.loom。
    assert Ezagent.UI.Form.implements?(LoomSession)

    names = Enum.map(Ezagent.UI.Form.list_form_classes(), fn {name, _mod, _fields} -> name end)
    assert "session.loom" in names

    # 对齐 loom-stitch:loom 表单字段只有 session_name(operator_uri 可选,缺省默认 ws admin)。
    field_names = Enum.map(LoomSession.form_fields(), & &1.name)
    assert field_names == ["session_name"]
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

    # operator_uri 可选(loom-stitch 对齐):缺省 → :ok(instantiate 默认 ws admin)。
    assert :ok =
             LoomSession.validate(%{
               "class" => "session.loom",
               "session_name" => "main"
             })

    # 提供但非法 user URI → 报错。
    assert {:error, _} =
             LoomSession.validate(%{
               "class" => "session.loom",
               "session_name" => "main",
               "operator_uri" => "not-a-user-uri"
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
