defmodule Ezagent.World.RoleAssignmentOwnerGateTest do
  @moduledoc """
  #224 / #1663 review residual #1 — the `session.assign_role` owner-gate was
  code-trace-only (no test). `Behavior.Session.action(:assign_role)` requires
  `caps: [:assign_role]`, which only the session owner holds (JIT, owner-rooted);
  a plain participation-tier member does NOT. This locks it structurally:

    * a NON-owner session member (participation tier only) invoking
      `session.assign_role` through the REAL world dispatch path is refused with
      a cap denial (`error:missing_cap`) — the action body never runs.

  Drives the real `Ezagent.World.ConversationActions.handle_dispatch/3`, not a
  re-implemented copy of the gate.
  """
  use EzagentCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Ezagent.World.ConversationActions

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

  defp confirmed_user(ws, prefix) do
    uri = URI.new!("entity://#{ws}/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp new_session(owner) do
    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "role-conv-#{uniq()}",
        owner,
        template_name: "default"
      )

    session_uri
  end

  defp bare_socket(caller) do
    %Phoenix.LiveView.Socket{}
    |> assign(:current_entity_uri, caller)
    |> assign(:current_workspace_uri, Ezagent.Capability.workspace_of(caller))
    |> assign(:last_dispatch_status, "idle")
    |> assign(:world_state, %{})
    |> assign(:world_state_json, "{}")
  end

  defp socket_with_join_cap(caller, session_uri) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, caller)
    :ok = Ezagent.IdentityCaps.grant(caller, cap)
    bare_socket(caller)
  end

  defp assign_role(socket, session_uri, target, role_name) do
    ConversationActions.handle_dispatch(socket, "session.assign_role", %{
      "session_uri" => URI.to_string(session_uri),
      "member" => URI.to_string(target),
      "role_name" => role_name
    })
  end

  test "(C) session.assign_role is owner-gated — owner clears the cap gate, a non-owner member is refused :missing_cap" do
    ws = "wrole-#{uniq()}"
    owner = confirmed_user(ws, "owner")
    member = confirmed_user(ws, "member")
    session_uri = new_session(owner)

    # `member` is a genuine participation-tier session member.
    {:noreply, _} =
      ConversationActions.invite_member(
        socket_with_join_cap(owner, session_uri),
        session_uri,
        URI.to_string(member)
      )

    assert member in Ezagent.Session.Participants.list_participants(session_uri),
           "setup failed: member never joined (so the refusal would be about membership, not role authority)"

    # A role name that no template declares — so the OWNER (who DOES hold the
    # owner-rooted `:assign_role` cap minted at create) clears the cap gate and
    # fails DOWNSTREAM on the undeclared role, never with `:missing_cap`. This is
    # the discriminator that proves the gate is about OWNERSHIP, not just an
    # unprovisioned caller: same call, same setup, different caller.
    undeclared_role = "no-such-role-#{uniq()}"

    # DISCRIMINATOR — the owner is NOT blocked by the cap gate (handler runs).
    {:noreply, owner_out} =
      assign_role(bare_socket(owner), session_uri, member, undeclared_role)

    refute owner_out.assigns.last_dispatch_status == "error:missing_cap",
           "the OWNER must clear the :assign_role cap gate (holds the owner-rooted cap), got: " <>
             "#{inspect(owner_out.assigns.last_dispatch_status)}"

    # THE LOCK — a non-owner member (participation tier only, no `:assign_role`)
    # is refused at the cap gate; the action body never runs.
    {:noreply, member_out} =
      assign_role(bare_socket(member), session_uri, member, undeclared_role)

    assert member_out.assigns.last_dispatch_status == "error:missing_cap",
           "a non-owner member must be refused by the :assign_role cap gate (handler must not run), got: " <>
             "#{inspect(member_out.assigns.last_dispatch_status)}"
  end
end
