defmodule Ezagent.World.PublishTemplateOwnerGateTest do
  @moduledoc """
  #224 Blocker B — resolved via Option B (no owner cap escalation).

  The world "publish" button (`session.publish_template` →
  `Ezagent.Session.Config.execute("save_template_as", …)`) used to pass the
  HUMAN session owner as the principal. That hit the orchestrator-scoped
  `:write_session_templates` admission gate, which no human owner holds, so a
  world owner's publish failed `:unauthorized`.

  Option B routes the publish through the SAME admin-operator authority the
  orchestrator/chat-publish path uses (the admin URI is the principal, and the
  DispatchPolicyAdapter materializes the exact admin action-cap), GATED by an
  un-forgeable "caller is the session owner (or system admin)" check. No owner
  cap is granted.

    * (A) the session OWNER publishes → a SessionTemplate is created in the
      session's workspace and shows in the owner's template list. RED before the
      fix (owner lacked the cap), GREEN after.
    * (B) a NON-owner session member (participation tier only, NOT ownership)
      publishes → REFUSED (`error:unauthorized`) and NO template is created —
      the structural owner-gate, not a cap accident.
  """
  use EzagentCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Ezagent.World.ConversationActions
  alias Ezagent.World.WorkspacePluginData

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)
    {:ok, _apps} = Application.ensure_all_started(:ezagent_plugin_world)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    assert "entity" in Ezagent.SpawnRegistry.registered_schemes(),
           "entity spawn scheme not registered — test environment bootstrap is incomplete"

    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  # A durable, spawned workspace member (mirrors production: `create_user` at the
  # workspace facade adds the user to `member_uris`, so the world session owner
  # is a DECLARED workspace member — the fact the roster-gated template list
  # reads).
  defp workspace_member(ws, workspace_uri, prefix) do
    uri = URI.new!("entity://#{ws}/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    :ok = Ezagent.Workspace.add_member(ws, uri)
    _ = workspace_uri
    uri
  end

  defp live_workspace do
    ws = "wpub-#{uniq()}"
    {:ok, _pid} = Ezagent.Workspace.create(ws, %{})
    {ws, Ezagent.URI.workspace(ws)}
  end

  defp new_session(owner, workspace_uri) do
    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "pub-conv-#{uniq()}",
        owner,
        template_name: "default",
        workspace_uri: workspace_uri
      )

    session_uri
  end

  defp bare_socket(caller, workspace_uri) do
    %Phoenix.LiveView.Socket{}
    |> assign(:current_entity_uri, caller)
    |> assign(:current_workspace_uri, workspace_uri)
    |> assign(:last_dispatch_status, "idle")
    |> assign(:world_state, %{})
    |> assign(:world_state_json, "{}")
  end

  # Grant the caller a signed per-session action cap so `invite_member` clears
  # the CapBAC join chokepoint (mirrors `remove_participant_authz_test.exs`).
  defp socket_with_join_cap(caller, workspace_uri, session_uri) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, caller)
    :ok = Ezagent.IdentityCaps.grant(caller, cap)
    bare_socket(caller, workspace_uri)
  end

  defp publish(socket, session_uri, name) do
    ConversationActions.handle_dispatch(socket, "session.publish_template", %{
      "session_uri" => URI.to_string(session_uri),
      "name" => name
    })
  end

  defp template_names(caller, workspace_uri),
    do: WorkspacePluginData.session_template_names(caller, workspace_uri)

  test "(A) the session OWNER can publish — template lands in the session workspace and shows for the owner" do
    {ws, workspace_uri} = live_workspace()
    owner = workspace_member(ws, workspace_uri, "owner")
    session_uri = new_session(owner, workspace_uri)

    # Liveness preconditions: the admin action-cap only materializes when the
    # workspace Kind is alive, and the owner-gate + save_template_as read the
    # live session.
    assert Ezagent.LocalRuntime.kind_alive?(workspace_uri),
           "workspace Kind must be live for admin action-cap materialization"

    assert {:ok, ^owner} = Ezagent.Entity.Session.owner(session_uri),
           "session must be live and owned by the publishing owner"

    template_name = "pub-tmpl-#{uniq()}"

    refute template_name in template_names(owner, workspace_uri)

    {:noreply, out} = publish(bare_socket(owner, workspace_uri), session_uri, template_name)

    assert out.assigns.last_dispatch_status == "ok",
           "owner publish must succeed under admin-operator authority, got: " <>
             "#{inspect(out.assigns.last_dispatch_status)} / #{inspect(out.assigns.world_state)}"

    # Landed in the SESSION's workspace AND visible to the owner (display refresh
    # via the roster-gated template list — the owner is a declared member).
    assert template_name in template_names(owner, workspace_uri),
           "published template must appear in the owner's workspace template list"
  end

  test "(B) a NON-owner session member CANNOT publish — refused, no template created" do
    {ws, workspace_uri} = live_workspace()
    owner = workspace_member(ws, workspace_uri, "owner")
    member = workspace_member(ws, workspace_uri, "member")
    session_uri = new_session(owner, workspace_uri)

    # Make `member` a real participation-tier session member. The gate must
    # still refuse them: authorization is OWNERSHIP, not membership.
    {:noreply, _} =
      ConversationActions.invite_member(
        socket_with_join_cap(owner, workspace_uri, session_uri),
        session_uri,
        URI.to_string(member)
      )

    assert member in Ezagent.Session.Participants.list_participants(session_uri),
           "setup failed: member never joined"

    before = template_names(owner, workspace_uri)
    template_name = "pub-tmpl-#{uniq()}"

    {:noreply, out} = publish(bare_socket(member, workspace_uri), session_uri, template_name)

    assert out.assigns.last_dispatch_status == "error:unauthorized",
           "a non-owner member must be refused by the structural owner-gate, got: " <>
             "#{inspect(out.assigns.last_dispatch_status)}"

    # No template was created — the owner-gate refused BEFORE any operator
    # dispatch, so nothing landed in the workspace.
    refute template_name in template_names(owner, workspace_uri),
           "a refused publish must NOT create a template"

    assert template_names(owner, workspace_uri) == before,
           "a refused publish must not mutate the workspace template list"
  end
end
