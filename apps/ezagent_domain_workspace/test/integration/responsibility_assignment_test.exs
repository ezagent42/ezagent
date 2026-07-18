defmodule Ezagent.Workspace.ResponsibilityAssignmentTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Workspace}
  alias Ezagent.Entity.User
  alias Ezagent.Workspace.ResponsibilityAssignment

  defp workspace_name do
    "p9-resp-#{System.unique_integer([:positive])}"
  end

  defp admin_ctx(workspace_uri), do: signed_workspace_ctx!(workspace_uri)

  defp spawn_user(uri) do
    case Ezagent.Kind.spawn(User, %{uri: uri}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp spawn_session(name, short_name) do
    session_uri = Ezagent.URI.session(name, :default, short_name)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: session_uri,
        owner_uri: User.admin_uri(),
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.URI.workspace(name))
    session_uri
  end

  defp has_cap?(caps, needed) do
    Enum.any?(caps, &Capability.matches?(&1, needed))
  end

  test "assign_role durably assigns supervisor and grants the workspace cap bundle" do
    name = workspace_name()
    {:ok, _pid} = Workspace.create(name, %{})
    workspace_uri = Ezagent.URI.workspace(name)
    holder = Ezagent.URI.user(name, "supervisor")
    :ok = spawn_user(holder)
    session_uri = spawn_session(name, "case")

    assert {:ok, assignment} =
             Workspace.assign_role(
               workspace_uri,
               "supervisor",
               holder,
               %{quorum_policy: "any_one"},
               admin_ctx(workspace_uri)
             )

    assert assignment.responsibility == "supervisor"
    assert ResponsibilityAssignment.holders(workspace_uri, "supervisor") == [holder]
    assert ResponsibilityAssignment.assigned?(workspace_uri, "supervisor", holder)

    needed_read =
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :read_unfiltered,
        session_uri,
        workspace_uri
      )

    needed_claim =
      Capability.cap(:session, Ezagent.ActionSet.Turn, :claim, session_uri, workspace_uri)

    needed_settle =
      Capability.cap(:session, Ezagent.ActionSet.Turn, :settle, session_uri, workspace_uri)

    needed_approve =
      Capability.cap(:session, Ezagent.ActionSet.Surface, :approve, session_uri, workspace_uri)

    needed_commit =
      Capability.cap(
        :session,
        Ezagent.ActionSet.Surface,
        :commit_settlement,
        session_uri,
        workspace_uri
      )

    needed_verdict =
      Capability.cap(
        :session,
        Ezagent.ActionSet.SupervisorApproval,
        :submit_verdict,
        session_uri,
        workspace_uri
      )

    caps = Ezagent.Identity.list_caps_for(holder)

    assert has_cap?(caps, needed_read)
    assert has_cap?(caps, needed_claim)
    assert has_cap?(caps, needed_settle)
    assert has_cap?(caps, needed_approve)
    assert has_cap?(caps, needed_commit)
    assert has_cap?(caps, needed_verdict)
  end

  test "assign_role cap holder can assign supervisor without IdentityAdmin grant authority" do
    name = workspace_name()
    {:ok, _pid} = Workspace.create(name, %{})
    workspace_uri = Ezagent.URI.workspace(name)
    assigner = Ezagent.URI.user(name, "assigner")
    holder = Ezagent.URI.user(name, "delegated-supervisor")
    :ok = spawn_user(assigner)
    :ok = spawn_user(holder)
    session_uri = spawn_session(name, "delegated")

    assign_cap =
      Capability.cap(
        :workspace,
        Ezagent.ActionSet.Workspace,
        :assign_role,
        workspace_uri,
        workspace_uri
      )

    :ok = Ezagent.Identity.Grant.grant_cap(assigner, assign_cap, {:admin, User.admin_uri()})

    assert {:ok, _assignment} =
             Workspace.assign_role(
               workspace_uri,
               "supervisor",
               holder,
               %{},
               %{caller: assigner, caps: Ezagent.Identity.list_caps_for(assigner)}
             )

    needed = Capability.cap(:session, Ezagent.ActionSet.Turn, :claim, session_uri, workspace_uri)

    assert has_cap?(Ezagent.Identity.list_caps_for(holder), needed)
  end

  test "unassign_role removes assignment and revokes the supervisor cap bundle" do
    name = workspace_name()
    {:ok, _pid} = Workspace.create(name, %{})
    workspace_uri = Ezagent.URI.workspace(name)
    holder = Ezagent.URI.user(name, "supervisor-remove")
    :ok = spawn_user(holder)
    session_uri = spawn_session(name, "case")

    assert {:ok, _} =
             Workspace.assign_role(
               workspace_uri,
               "supervisor",
               holder,
               %{},
               admin_ctx(workspace_uri)
             )

    assert :ok =
             Workspace.unassign_role(
               workspace_uri,
               "supervisor",
               holder,
               admin_ctx(workspace_uri)
             )

    refute ResponsibilityAssignment.assigned?(workspace_uri, "supervisor", holder)
    needed =
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :read_unfiltered,
        session_uri,
        workspace_uri
      )

    refute has_cap?(Ezagent.Identity.list_caps_for(holder), needed)
  end

  test "assignment rejects a holder from another workspace" do
    name = workspace_name()
    {:ok, _pid} = Workspace.create(name, %{})
    workspace_uri = Ezagent.URI.workspace(name)
    foreign_holder = Ezagent.URI.user("other-#{name}", "supervisor")

    assert {:error, {:cross_workspace_member_not_permitted, ^foreign_holder, ^workspace_uri}} =
             Workspace.assign_role(
               workspace_uri,
               "supervisor",
               foreign_holder,
               %{},
               admin_ctx(workspace_uri)
             )
  end
end
