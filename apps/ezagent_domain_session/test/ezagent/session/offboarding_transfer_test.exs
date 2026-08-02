defmodule Ezagent.Session.OffboardingTransferTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.Authority
  alias Ezagent.Identity.Offboarding.RevocationFence
  alias Ezagent.Provenance.DerivationEdges
  alias Ezagent.Workspace.Store

  test "delete_user transfers an owned session to its workspace owner without bumping the session" do
    suffix = System.unique_integer([:positive])
    workspace_name = "offboarding-session-#{suffix}"
    deleted_user = Ezagent.URI.user(workspace_name, "deleted-#{suffix}")
    workspace_owner = Ezagent.URI.user(workspace_name, "workspace-owner-#{suffix}")
    session_uri = Ezagent.URI.session(workspace_name, "offboarding", "owned-#{suffix}")

    assert {:ok, _} = Ezagent.Users.create(deleted_user, nil, [])
    assert {:ok, _} = Ezagent.Users.create(workspace_owner, nil, [])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(deleted_user)
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(workspace_owner)
    await_ready(deleted_user)
    await_ready(workspace_owner)

    assert {:ok, _workspace} = Store.create(workspace_name, %{created_by: workspace_owner})

    assert {:ok, session_pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
               uri: session_uri,
               behaviors: Ezagent.Entity.Session.behaviors(),
               owner_uri: deleted_user
             })

    on_exit(fn ->
      if Process.alive?(session_pid), do: Ezagent.Kind.terminate(session_uri)
    end)

    assert :ok =
             Ezagent.WorkspaceRegistry.bind(
               session_uri,
               Ezagent.Capability.workspace_of(session_uri)
             )

    await_ready(session_uri)

    assert :ok =
             DerivationEdges.record_derivation_edge(
               session_uri,
               deleted_user,
               :created_by,
               DerivationEdges.new_attempt_id()
             )

    assert {:ok, generation} = Authority.current_generation(session_uri)
    assert {:ok, ^deleted_user} = Ezagent.Entity.Session.owner(session_uri)

    assert :ok = Ezagent.Users.delete(deleted_user)

    assert {:ok, ^workspace_owner} = Ezagent.Entity.Session.owner(session_uri)
    assert {:ok, ^generation} = Authority.current_generation(session_uri)
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(session_uri)
    refute RevocationFence.fenced?(session_uri)
    assert session_uri in DerivationEdges.descendants(workspace_owner)

    assert Enum.any?(Ezagent.IdentityCaps.load(workspace_owner), fn cap ->
             cap.kind == :session and cap.behavior == Ezagent.ActionSet.Session and
               Ezagent.Capability.action_of(cap) == :receive and cap.instance == session_uri
           end)
  end

  test "delete_user transfers a forked template to its workspace owner without bumping it" do
    suffix = System.unique_integer([:positive])
    workspace_name = "offboarding-template-#{suffix}"
    deleted_user = Ezagent.URI.user(workspace_name, "deleted-#{suffix}")
    workspace_owner = Ezagent.URI.user(workspace_name, "workspace-owner-#{suffix}")
    template_uri = Ezagent.URI.template(workspace_name, :agent, "owned-#{suffix}")
    admin = Ezagent.Entity.User.admin_uri()

    assert {:ok, _} = Ezagent.Users.create(deleted_user, nil, [])
    assert {:ok, _} = Ezagent.Users.create(workspace_owner, nil, [])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(deleted_user)
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(workspace_owner)
    await_ready(deleted_user)
    await_ready(workspace_owner)
    assert {:ok, _workspace} = Store.create(workspace_name, %{created_by: workspace_owner})

    assert {:ok, template_pid} = Ezagent.SpawnRegistry.spawn(template_uri)

    on_exit(fn ->
      if Process.alive?(template_pid), do: Ezagent.Kind.terminate(template_uri)
    end)

    await_ready(template_uri)
    write_target = Ezagent.URI.with_action(template_uri, :template, :write)
    assert {:ok, write_cap} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, write_target)

    assert {:ok, _result} =
             Ezagent.Invocation.dispatch(%Ezagent.Invocation{
               target: write_target,
               mode: :call,
               args: %{
                 content: %{
                   flavor: "cc",
                   project_cwd: "/tmp",
                   default_caps: [],
                   created_by: deleted_user,
                   created_at: DateTime.utc_now()
                 }
               },
               ctx: %{
                 caller: admin,
                 authenticated_principal: admin,
                 caps: MapSet.new([write_cap]),
                 reply: {:caller_inbox, self()}
               },
               origin: :trusted_internal
             })

    assert :ok =
             DerivationEdges.record_derivation_edge(
               template_uri,
               deleted_user,
               :created_by,
               DerivationEdges.new_attempt_id()
             )

    assert {:ok, generation} = Authority.current_generation(template_uri)
    assert :ok = Ezagent.Users.delete(deleted_user)

    assert {:ok, slice} = Ezagent.Kind.read(template_uri, :template, spawn: :never)
    content = slice |> Ezagent.Kind.normalize_slice_view() |> Map.fetch!(:content)
    assert content.created_by == workspace_owner
    assert {:ok, ^generation} = Authority.current_generation(template_uri)
    refute RevocationFence.fenced?(template_uri)
    assert template_uri in DerivationEdges.descendants(workspace_owner)

    assert Enum.any?(Ezagent.IdentityCaps.load(workspace_owner), fn cap ->
             cap.instance == template_uri
           end)
  end

  defp await_ready(uri, attempts \\ 200)

  defp await_ready(_uri, 0), do: flunk("principal did not become ready")

  defp await_ready(uri, attempts) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        Process.sleep(10)
        await_ready(uri, attempts - 1)
    end
  end
end
