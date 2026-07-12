defmodule Ezagent.Session.Config.ExecuteTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Invocation}
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Session.Config, as: SessionConfig
  alias Ezagent.Session.Config.ExtensionRegistry

  setup do
    ExtensionRegistry.reset_for_test!()

    on_exit(fn ->
      ExtensionRegistry.reset_for_test!()
      ExtensionRegistry.assemble!(ExtensionRegistry.discover_loaded_extensions())
    end)

    :ok
  end

  test "execute/4 rejects unknown operations and malformed addressed targets at the domain boundary" do
    principal = User.admin_uri()
    session_uri = Ezagent.URI.new!("session://system/default/session-config-boundary")

    assert SessionConfig.execute("not_real", %{}, principal, session_uri) ==
             {:error, {:unknown_operation, "not_real"}}

    assert SessionConfig.execute("remove_member", %{}, principal, :request_supplied_context) ==
             {:error, {:invalid_addressed_target, :request_supplied_context}}
  end

  test "operation names are normalized without converting request strings to atoms" do
    assert SessionConfig.operation("list_templates").name == "list_templates"
    assert SessionConfig.operation(:list_templates).name == "list_templates"
    refute Enum.any?(Ezagent.Session.Config.Catalog.core_operations(), &(&1.name == "kb_query"))
  end

  test "equal principal and addressed target inputs derive one canonical context" do
    :ok =
      ExtensionRegistry.assemble!([
        %{
          name: "context_probe",
          description: "test probe",
          input_schema: %{"type" => "object", "properties" => %{}, "required" => []},
          target_scope: :workspace,
          admission_gate: :workspace_caps,
          route: {:mfa, __MODULE__, :capture_context}
        }
      ])

    principal = User.admin_uri()
    workspace_uri = Ezagent.URI.new!("workspace://system")

    assert {:ok, opts} = SessionConfig.execute("context_probe", %{}, principal, workspace_uri)
    assert opts[:caller] == principal
    assert opts[:owner] == principal
    assert opts[:workspace_uri] == workspace_uri
    assert opts[:session_uri] == nil
    assert %MapSet{} = opts[:caps]
  end

  test "session operations fail readiness before admission and admit the live owner" do
    assemble_probe("session_probe", :session, :session_membership)
    principal = User.admin_uri()
    session_uri = session_uri("readiness")

    assert {:error, {:gate_failed, :readiness, _status}} =
             SessionConfig.execute("session_probe", %{}, principal, session_uri)

    spawn_session(session_uri, principal)

    assert {:ok, opts} = SessionConfig.execute("session_probe", %{}, principal, session_uri)
    assert opts[:session_uri] == session_uri
    assert opts[:owner] == principal
  end

  test "session-membership admission rejects strangers and accepts roster members holding member-cap" do
    assemble_probe("member_probe", :session, :session_membership)
    owner = User.admin_uri()
    session_uri = session_uri("membership")
    spawn_session(session_uri, owner)

    stranger = create_user("stranger")

    assert SessionConfig.execute("member_probe", %{}, stranger, session_uri) ==
             {:error, {:gate_failed, :session_membership, :unauthorized}}

    member = create_user("member")
    assert :ok = join_session(session_uri, member, owner)
    assert eventually(fn -> member_cap?(member, session_uri) end)

    assert {:ok, opts} = SessionConfig.execute("member_probe", %{}, member, session_uri)
    assert opts[:caller] == member
  end

  test "workspace admission preserves per-kind list_templates subsets without a session" do
    workspace_uri = Ezagent.URI.workspace("team-alpha")
    principal = create_user("workspace-operator")
    grant_template_cap(principal, :agent_template, workspace_uri)

    assert {:ok, result} =
             SessionConfig.execute("list_templates", %{}, principal, workspace_uri)

    assert is_list(result.agent_templates)
    assert result.session_templates == []

    assert {:ok, nil_target_result} =
             SessionConfig.execute("list_templates", %{}, principal, nil)

    assert nil_target_result.session_templates == []
  end

  test "template-write admission uses its cap and does not invent session membership" do
    assemble_probe("template_probe", :session, :template_write)
    owner = User.admin_uri()
    session_uri = session_uri("template-write")
    spawn_session(session_uri, owner)

    principal = create_user("template-writer")
    workspace_uri = Capability.workspace_of(session_uri)
    grant_template_cap(principal, :session_template, workspace_uri)

    assert {:ok, opts} = SessionConfig.execute("template_probe", %{}, principal, session_uri)
    assert opts[:caller] == principal
  end

  defp assemble_probe(name, scope, gate) do
    :ok =
      ExtensionRegistry.assemble!([
        %{
          name: name,
          description: "admission probe",
          input_schema: %{"type" => "object", "properties" => %{}, "required" => []},
          target_scope: scope,
          admission_gate: gate,
          route: {:mfa, __MODULE__, :capture_context}
        }
      ])
  end

  defp session_uri(label) do
    Ezagent.URI.session(
      "team-alpha",
      "generic",
      "session-config-#{label}-#{System.unique_integer([:positive])}"
    )
  end

  defp spawn_session(session_uri, owner) do
    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Session.behaviors(),
        owner_uri: owner
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, Capability.workspace_of(session_uri))
  end

  defp create_user(prefix) do
    uri = Ezagent.URI.user("team-alpha", "#{prefix}-#{System.unique_integer([:positive])}")
    {:ok, _row} = Ezagent.Users.create(uri, "test-password", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    :ok = Ezagent.WorkspaceRegistry.bind(uri, Capability.workspace_of(uri))
    uri
  end

  defp join_session(session_uri, member, owner) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
      mode: :call,
      args: %{member: member, role_name: "member"},
      ctx: %{
        caller: owner,
        caps: MapSet.new([Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
    |> case do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp member_cap?(principal, session_uri) do
    principal
    |> Ezagent.Identity.read_entity_caps()
    |> Ezagent.Session.MemberReceive.holds_member_cap_over?(session_uri)
  end

  defp grant_template_cap(principal, kind, workspace_uri) do
    cap =
      Capability.cap(
        kind,
        Ezagent.ActionSet.Template,
        :any,
        {:within_workspace, workspace_uri},
        workspace_uri
      )

    :ok = Ezagent.Identity.grant_cap(principal, cap, User.admin_uri())
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  def capture_context(_args, opts), do: {:ok, opts}
end
