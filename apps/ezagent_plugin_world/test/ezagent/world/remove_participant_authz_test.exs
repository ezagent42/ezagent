defmodule Ezagent.World.RemoveParticipantAuthzTest do
  @moduledoc """
  P2 test-supplement — `Ezagent.World.ConversationActions.remove_participant/3`
  had ZERO behavior test despite being a member-removal authz edge (F7 PR-A).
  `invite_member/3` already has `admission_gate_world_invite_test.exs`; this is
  its missing counterpart on the removal side.

  Drives the REAL public handler (not a re-implemented copy of the gate):

    * a session OWNER can remove a different participant — the positive path.
    * an OUTSIDER (no caps, not the owner, not a participant) attempting to
      remove a DIFFERENT participant is DENIED — `Ezagent.Session.Participants`
      dispatches under the CALLER's live caps, so a zero-cap caller fails the
      chokepoint — and the target stays a member (no partial mutation).
    * world's OWN UI-level guard rejects a caller trying to `remove_participant`
      on THEMSELVES (`error:self_remove_not_allowed`) before any domain call —
      distinct from (and stricter than) the domain's self-leave allowance.
    * a malformed participant URI degrades to `error:bad_member_uri`, not a
      crash.
  """
  use EzagentCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Ezagent.Capability
  alias Ezagent.World.ConversationActions

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    assert "entity" in Ezagent.SpawnRegistry.registered_schemes(),
           "entity spawn scheme not registered — test environment bootstrap is incomplete"

    :ok
  end

  defp uniq, do: System.unique_integer([:positive])
  defp new_ws, do: "wremove-#{uniq()}"

  defp confirmed_user(ws, prefix) do
    uri = URI.new!("entity://#{ws}/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp new_session(owner) do
    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "rm-conv-#{uniq()}",
        owner,
        template_name: "default"
      )

    session_uri
  end

  # A socket carrying the caller's identity + a durably-granted signed action
  # cap for `target_action` on `session_uri` (mirrors
  # `admission_gate_world_invite_test.exs`'s `invite_socket/2` — the chokepoint
  # still reads the caller's DURABLE caps live, so this only clears the CapBAC
  # gate, it does not forge the domain-level owner/self/admin identity gate).
  defp socket_with_cap(caller, session_uri, target_action) do
    target = Ezagent.URI.with_action(session_uri, :session, target_action)
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, caller)
    :ok = Ezagent.EntityCaps.grant(caller, cap)

    %Phoenix.LiveView.Socket{}
    |> assign(:current_entity_uri, caller)
    |> assign(:current_workspace_uri, Capability.workspace_of(caller))
    |> assign(:last_dispatch_status, "idle")
    |> assign(:world_state, %{"layout" => %{}})
    |> assign(:world_state_json, "{}")
  end

  defp bare_socket(caller) do
    %Phoenix.LiveView.Socket{}
    |> assign(:current_entity_uri, caller)
    |> assign(:current_workspace_uri, Capability.workspace_of(caller))
    |> assign(:last_dispatch_status, "idle")
    |> assign(:world_state, %{"layout" => %{}})
    |> assign(:world_state_json, "{}")
  end

  defp members_of(session_uri), do: Ezagent.Session.Participants.list_participants(session_uri)

  test "the session owner CAN remove a different participant" do
    ws = new_ws()
    owner = confirmed_user(ws, "owner")
    member = confirmed_user(ws, "member")
    session_uri = new_session(owner)

    {:noreply, _} =
      ConversationActions.invite_member(
        socket_with_cap(owner, session_uri, :join),
        session_uri,
        URI.to_string(member)
      )

    assert member in members_of(session_uri), "setup failed: member never joined"

    {:noreply, out} =
      ConversationActions.remove_participant(
        socket_with_cap(owner, session_uri, :remove_participant),
        session_uri,
        URI.to_string(member)
      )

    assert out.assigns.last_dispatch_status == "ok"
    refute member in members_of(session_uri)
  end

  test "an OUTSIDER with no caps CANNOT remove a different participant (no partial mutation)" do
    ws = new_ws()
    owner = confirmed_user(ws, "owner")
    member = confirmed_user(ws, "member")
    outsider = confirmed_user(ws, "outsider")
    session_uri = new_session(owner)

    {:noreply, _} =
      ConversationActions.invite_member(
        socket_with_cap(owner, session_uri, :join),
        session_uri,
        URI.to_string(member)
      )

    assert member in members_of(session_uri), "setup failed: member never joined"

    {:noreply, out} =
      ConversationActions.remove_participant(
        bare_socket(outsider),
        session_uri,
        URI.to_string(member)
      )

    assert out.assigns.last_dispatch_status =~ "error:",
           "an outsider with zero caps must be denied, got: #{inspect(out.assigns.last_dispatch_status)}"

    assert member in members_of(session_uri),
           "LEAK: an unauthorized remove must not mutate membership"
  end

  test "world's UI guard rejects a caller trying to remove THEMSELVES" do
    ws = new_ws()
    owner = confirmed_user(ws, "owner")
    session_uri = new_session(owner)

    {:noreply, out} =
      ConversationActions.remove_participant(
        socket_with_cap(owner, session_uri, :remove_participant),
        session_uri,
        URI.to_string(owner)
      )

    assert out.assigns.last_dispatch_status == "error:self_remove_not_allowed"
    # No domain call was even attempted — the owner is still (trivially) a
    # session participant per the create-time bootstrap.
  end

  test "a malformed participant URI degrades to error:bad_member_uri (no crash)" do
    ws = new_ws()
    owner = confirmed_user(ws, "owner")
    session_uri = new_session(owner)

    {:noreply, out} =
      ConversationActions.remove_participant(
        socket_with_cap(owner, session_uri, :remove_participant),
        session_uri,
        "not a uri"
      )

    assert out.assigns.last_dispatch_status == "error:bad_member_uri"
  end
end
