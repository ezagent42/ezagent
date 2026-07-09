defmodule EzagentDomainInstanceMessage.Integration.GenericSessionCreateViaWorkspaceTest do
  @moduledoc """
  Defect 2 regression — `Ezagent.Workspace.create_session/3` with a `generic`
  template routes through `Behavior.Workspace.create_session_via_class/5` →
  `Ezagent.Template.GenericSession.instantiate/3`, which returns the **2-element**
  `{:ok, [session_uri]}` shape. That shape is explicitly VALID per the
  `Ezagent.Kind.Template` `@callback instantiate` (both `{:ok, [URI.t()]}` and
  `{:ok, [URI.t()], meta}` are allowed).

  Pre-fix, the class-path `case` only matched the 3-element
  `{:ok, [uri | _], meta}` head (plus its `{:ok, _non_session, _meta}` mirror), so
  a 2-element return fell through with no clause and every `generic` create
  crashed with the live symptom:

      {:behavior_exception, :error,
       {:case_clause, {:ok, [%URI{scheme: "session", path: "/generic/echo-generic"}]}}}
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Template.GenericSession

  setup do
    # Ensure the `session.generic` class is resolvable by `resolve_session_class`.
    :ok = Ezagent.TemplateRegistry.register(GenericSession)

    ws_name = "generic-create-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = Ezagent.URI.workspace(ws_name)

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  test "generic-template create returns the session (no case_clause on the 2-element instantiate)",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    short = "echo-generic-#{System.unique_integer([:positive])}"

    assert {:ok, %{session_uri: session_uri}} =
             Workspace.create_session(
               workspace_uri,
               %{short_name: short, template_name: "generic"},
               admin_ctx
             )

    assert URI.to_string(session_uri) == "session://#{ws_name}/generic/#{short}"

    # The class path actually spawned the Session Kind.
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(session_uri)
  end
end
