defmodule Ezagent.Session.RoleAssignmentTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Capability
  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{Definition, DefinitionRegistry, Installation}
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2, signed_required_cap!: 5]

  @workspace URI.new!("workspace://system")

  defp uniq, do: System.unique_integer([:positive])

  defp confirmed_user(prefix) do
    uri = URI.new!("entity://system/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp live_session(owner) do
    session_uri = Ezagent.URI.session("system", "generic", "assign-role-#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        owner_uri: owner,
        behaviors: Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace)
    on_exit(fn -> Ezagent.Kind.terminate(session_uri) end)
    session_uri
  end

  defp install_human_slot!(session_uri, actor, role_name) do
    name = "human-slot-#{uniq()}"

    {:ok, definition} =
      Definition.new(%{
        name: name,
        bases: [Ezagent.ActionSet.Session],
        roles: [%{role_name: role_name, fill: :human}]
      })

    {:ok, _object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: @workspace,
        caller_workspace_uri: @workspace,
        actor_uri: actor
      )

    :ok =
      Installation.install_template_installs(session_uri, @workspace, %{installs: [name]}, actor)

    definition
  end

  defp join_user(session_uri, user_uri) do
    caller = Ezagent.Entity.User.admin_uri()
    target = Ezagent.URI.with_action(session_uri, :session, :join)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{member: user_uri},
      ctx: %{
        caller: caller,
        caps: MapSet.new([signed_action_cap!(target, caller)]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp members_of(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{state: %{members: members}}} -> members
      {:ok, %{members: members}} -> members
      _ -> %{}
    end
  end

  defp assign_cap(session_uri, caller) do
    signed_required_cap!(
      session_uri,
      :session,
      Ezagent.ActionSet.Session,
      :assign_role,
      caller
    )
  end

  test "operator assigns an open human role to a joined user edge only" do
    owner = confirmed_user("owner")
    user = confirmed_user("reviewer")
    session_uri = live_session(owner)
    definition = install_human_slot!(session_uri, owner, "reviewer")

    assert {:ok, _} = join_user(session_uri, user)

    assert {:ok, %{member: ^user, role_name: "reviewer"}} =
             Ezagent.Session.RoleAssignments.assign_role(session_uri, user, "reviewer", %{
               caller: owner,
               caps: MapSet.new([assign_cap(session_uri, owner)])
             })

    assert SessionBehavior.role_name_to_uri(members_of(session_uri), "reviewer") == user

    assert [%{role_name: "reviewer", fill: :human}] = definition.roles
    refute inspect(Definition.body(definition)) =~ URI.to_string(user)
  end

  test "human role assignment rejects agent targets" do
    owner = confirmed_user("owner")
    session_uri = live_session(owner)
    install_human_slot!(session_uri, owner, "reviewer")
    agent_uri = URI.new!("entity://system/agent/not-a-human")

    assert {:error, :assign_role_requires_user_uri} =
             Ezagent.Session.RoleAssignments.assign_role(session_uri, agent_uri, "reviewer", %{
               caller: owner,
               caps: MapSet.new([assign_cap(session_uri, owner)])
             })
  end
end
